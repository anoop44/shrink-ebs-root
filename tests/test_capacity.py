"""Capacity regressions without AWS access, root privileges, or real disk writes."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "shrink-ebs-root.sh"
SOURCE = SCRIPT.read_text()
HELPERS = SOURCE[SOURCE.index("check_capacity() {"):SOURCE.index('INSTANCE_ID=""')]
GIB = 1024**3


class CapacityTests(unittest.TestCase):
    def run_bash(self, body):
        return subprocess.run(
            ["bash", "-c", "set -Eeuo pipefail\n" + HELPERS + body],
            capture_output=True, text=True,
        )

    def test_enough_space_and_exact_boundary(self):
        for capacity in (15 * GIB, 16 * GIB):
            with self.subTest(capacity=capacity):
                result = self.run_bash(f"check_capacity {10 * GIB} {capacity} {5 * GIB} test")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_short_by_one_byte_is_rejected(self):
        result = self.run_bash(f"check_capacity {10 * GIB} {15 * GIB - 1} {5 * GIB} test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("short by 1 bytes", result.stderr)
        self.assertIn("Choose a larger --target-size", result.stderr)

    def test_zero_headroom_still_requires_room_for_data(self):
        self.assertEqual(self.run_bash("check_capacity 100 100 0 test").returncode, 0)
        self.assertNotEqual(self.run_bash("check_capacity 101 100 0 test").returncode, 0)

    def test_invalid_measurements_fail_closed(self):
        for value in ("", "garbage", "-1", "1.5", "9223372036854775808"):
            for index in range(3):
                args = ["10", "100", "5"]
                args[index] = value
                with self.subTest(value=value, index=index):
                    result = self.run_bash("check_capacity " + shlex.join(args + ["test"]))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("invalid capacity measurement", result.stderr)

    def test_estimate_accounts_for_overhead(self):
        result = self.run_bash(f"estimated_capacity {24 * GIB}")
        self.assertEqual(int(result.stdout), 24 * GIB - (24 * GIB // 10) - 1048576)
        for value in ("", "invalid", "0", "1048576"):
            self.assertNotEqual(self.run_bash("estimated_capacity " + shlex.quote(value)).returncode, 0)

    def guest(self, source_used, target_used, target_available, mode="filesystem", raw_size=24 * GIB):
        mocks = f'''
df() {{
  if [[ "$*" == *--output=used,avail* ]]; then
    printf 'Used Avail\\n%s %s\\n' {shlex.quote(str(target_used))} {shlex.quote(str(target_available))}
  else
    printf 'Used\\n%s\\n' {shlex.quote(str(source_used))}
  fi
}}
blockdev() {{ printf '%s\\n' {shlex.quote(str(raw_size))}; }}
check_guest_capacity /mock/target {mode} {5 * GIB}
'''
        return self.run_bash(mocks)

    def test_actual_raw_disk_too_small(self):
        result = self.guest(18 * GIB, 0, 0, mode="raw")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("insufficient target space", result.stderr)

    def test_formatted_capacity_can_reject_an_estimated_fit(self):
        # 10 + 5 fits the raw estimate, but not this filesystem's 14 GiB available.
        self.assertEqual(self.guest(10 * GIB, 0, 0, mode="raw").returncode, 0)
        result = self.guest(10 * GIB, 2 * GIB, 14 * GIB, mode="empty-filesystem")
        self.assertNotEqual(result.returncode, 0)

    def test_resync_does_not_double_count_existing_copy(self):
        result = self.guest(10 * GIB, 10 * GIB, 6 * GIB)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_source_growth_before_final_sync_aborts(self):
        result = self.guest(12 * GIB, 10 * GIB, 6 * GIB)
        self.assertNotEqual(result.returncode, 0)

    def test_guest_missing_or_negative_measurement_aborts(self):
        for source, used, available in (("", 0, 30 * GIB), (1, "", 30 * GIB), (1, 0, -1)):
            self.assertNotEqual(self.guest(source, used, available).returncode, 0)

    def test_embedded_guest_payloads_expand_to_valid_bash(self):
        # Expand the actual heredocs to catch quoting/escaping regressions in SSM.
        for match in re.finditer(r"(\w+)=\$\(cat <<(EOF\w*)\n(.*?)\n\2\n\)", SOURCE, re.S):
            name = match[1]
            body = "\n".join(f"{key}=test" for key in (
                "NEW_VOL", "NEW_SERIAL", "LEGACY_SERIAL", "SERVICES_SPACE", "MIN_FREE_BYTES"
            )) + "\n" + match[0] + f'\nprintf "%s" "${{{name}}}"\n'
            with self.subTest(payload=name):
                result = self.run_bash(body)
                self.assertEqual(result.returncode, 0, result.stderr)
                syntax = subprocess.run(["bash", "-n"], input=result.stdout, text=True, capture_output=True)
                self.assertEqual(syntax.returncode, 0, syntax.stderr)

    @unittest.skipUnless(shutil.which("jq"), "preflight integration test requires jq")
    def test_insufficient_preflight_stops_before_resource_creation(self):
        # Run the full entry point with a fake AWS executable. Any unrecognized
        # API call, including create-volume, fails and is recorded for inspection.
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            aws = temp / "aws"
            aws.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["AWS_TEST_LOG"], "a") as log:
    log.write(" ".join(args) + "\\n")
if "--generate-cli-skeleton" in args:
    print('{"VolumeId": ""}')
elif "describe-instances" in args:
    print(json.dumps({"Reservations": [{"Instances": [{
        "State": {"Name": "running"}, "Placement": {"AvailabilityZone": "test-1a"},
        "InstanceType": "m5.large", "RootDeviceName": "/dev/sda1", "RootDeviceType": "ebs",
        "BlockDeviceMappings": [{"DeviceName": "/dev/sda1", "Ebs": {
            "VolumeId": "vol-source", "DeleteOnTermination": True}}]
    }]}]}))
elif "describe-volumes" in args:
    print(json.dumps({"Volumes": [{"Size": 100, "VolumeType": "gp3",
        "Iops": 3000, "Throughput": 125, "Encrypted": False}]}))
elif "describe-instance-information" in args:
    print("Online")
elif "send-command" in args:
    print("mock-command")
elif "get-command-invocation" in args:
    if args[args.index("--query") + 1] == "Status":
        print("Success")
    else:
        print("ROOT_FS=ext4\\nPTTYPE=dos\\nPARTCOUNT=1\\nBOOTMODE=legacy\\n"
              "USED_BYTES=19327352832\\nLVM=0\\nRAID=0\\nROOT_PARTNUM=1")
else:
    sys.exit("Unexpected AWS operation: " + " ".join(args))
''')
            aws.chmod(0o755)
            log = temp / "aws.log"
            env = dict(os.environ, PATH=str(temp) + os.pathsep + os.environ["PATH"], AWS_TEST_LOG=str(log))
            result = subprocess.run([
                "bash", str(SCRIPT), "--instance-id", "i-1234abcd", "--target-size", "24",
                "--execute", "--yes", "--stop-services", "none",
            ], env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("insufficient target space", result.stderr)
            calls = log.read_text()
            self.assertEqual(calls.count("ssm send-command"), 1)
            self.assertNotIn("ec2 create-volume", calls)
            self.assertNotIn("ec2 attach-volume", calls)


if __name__ == "__main__":
    unittest.main()
