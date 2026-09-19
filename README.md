# shrink-ebs-root

Replace a supported Linux EC2 root EBS volume with a smaller, bootable gp3 volume.

**This is not an in-place size reduction.** The script does not reduce the size of
the existing EBS volume or shrink its filesystem. It creates a **new disk**, copies
the root filesystem to it, updates disk identifiers, installs GRUB to make it
bootable, and switches the instance to that new disk. EC2 reboots the instance
during the switch. You then validate your application and **manually delete the
old disk** when you no longer need rollback. The script never deletes the original
root volume.

The old disk continues to incur storage charges until you delete it. This script
does not create a backup snapshot. Take an appropriate backup and plan application
downtime before using `--execute`.

## Supported machines

This is intentionally a narrow migration tool, not a general disk-layout converter:

- A running Linux EC2 instance with an EBS root volume.
- NVMe EBS devices, as exposed by supported Nitro instances. Target discovery uses
  the EBS volume ID in the NVMe serial number; Xen `/dev/xvd*` targets are unsupported.
- x86 Legacy BIOS boot, DOS/MBR partition table, exactly one partition on the root
  disk, root on partition 1, and an ext4 root filesystem.
- A Debian/Ubuntu-style GRUB installation providing `grub-install`, `update-grub`,
  and the `i386-pc` GRUB target. The boot validation expects GRUB to generate
  `root=PARTUUID=...`; images using other root conventions can fail validation.
- No LVM, software RAID, device-mapper root, UEFI, GPT, XFS, Btrfs, separate boot
  partition, or guest-level encrypted root. EBS encryption is supported.
- A root volume larger than the requested replacement, and enough available EBS
  quota and instance attachment capacity to attach a second disk as `/dev/sdf`.
  That attachment name and `/mnt/root-shrink-new` must be available for this tool.

The guest preflight rejects unsupported filesystem, partition, and boot layouts.
It also rejects detected LVM or mdraid even when used outside the root disk.
The requirements above remain the operator's responsibility: the preflight does
not verify every compatibility condition or every IAM permission.

## Requirements

### On the computer running the script

- Bash (macOS or Linux), `jq`, and common Unix tools including `base64`, `awk`,
  `grep`, `tr`, `date`, and `wc`.
- AWS CLI v2 recent enough to support
  `ec2 create-replace-root-volume-task --volume-id`. The script checks the CLI's
  input skeleton and aborts if `VolumeId` is missing.
- AWS credentials for the intended account, a configured region or `--region`,
  and network access to the EC2 and Systems Manager APIs. Keep credentials valid
  throughout the migration; copying a large filesystem can take hours.

No SSH key or Session Manager CLI plugin is required. The script uses SSM Run
Command, not an interactive Session Manager session. AWS CLI credentials and
`jq` are needed on the operator's computer, not inside the guest.

### SSM Agent and instance access

1. Install and start Amazon SSM Agent on the instance, and enable it on boot.
   It must report `Online` in Systems Manager before starting, and must reconnect
   after the replacement boots. See [SSM Agent installation and operation](https://docs.aws.amazon.com/systems-manager/latest/userguide/ssm-agent.html).
2. Supply instance credentials for SSM, typically through an EC2 instance profile
   with `AmazonSSMManagedInstanceCore` or equivalent permissions. A correctly
   configured Default Host Management Configuration is another option. The
   operator's AWS profile does not replace the guest's SSM permissions. See
   [instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html).
3. Provide working DNS and outbound HTTPS connectivity to the regional SSM
   services, particularly `ssm` and `ssmmessages`, through public endpoints or
   VPC interface endpoints. Older agent/region combinations can also require
   `ec2messages`. Endpoint security groups must permit HTTPS from the instance;
   no inbound SSH connection is needed. See [SSM network requirements](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html).
4. Permit the `AWS-RunShellScript` document to run commands as root. This tool
   partitions disks, mounts filesystems, enters a chroot, and stops services.

Check connectivity using your actual profile, region, and instance ID:

```bash
aws --profile production --region ap-south-1 ssm describe-instance-information \
  --filters Key=InstanceIds,Values=i-0123456789abcdef0 \
  --query 'InstanceInformationList[0].PingStatus' --output text
# Must return Online
```

### Guest software

The guest needs Bash, GNU `df` supporting `-B1 --output`, standard core utilities,
and these commands:

```text
rsync sfdisk mkfs.ext4 grub-install update-grub findmnt lsblk blkid blockdev
wipefs partprobe udevadm e2fsck mount umount mountpoint chroot systemctl
base64 awk sed grep readlink head tail tr basename sync
```

`lsblk` must support `MOUNTPOINTS`. `rsync` must support ACLs, extended attributes,
hard links, sparse files, and the progress/statistics options used in the script.
Common Debian/Ubuntu package providers include `rsync`, `util-linux`, `fdisk`,
`e2fsprogs`, `parted`, `udev`, `grub-pc`, `grub-pc-bin`, `grub2-common`, and
`coreutils`. Package names vary by release; provision the appropriate BIOS GRUB
packages for the image before running this tool. It does not install software.

### Operator IAM and encryption permissions

The calling identity needs permissions for the operations the script performs:

| Purpose | IAM actions |
| --- | --- |
| Inspect instance, volumes, and health | `ec2:DescribeInstances`, `ec2:DescribeVolumes`, `ec2:DescribeInstanceStatus` |
| Create and prepare replacement | `ec2:CreateVolume`, `ec2:CreateTags`, `ec2:AttachVolume`, `ec2:DetachVolume` |
| Switch and track the root | `ec2:CreateReplaceRootVolumeTask`, `ec2:DescribeReplaceRootVolumeTasks` |
| Restore termination behavior | `ec2:ModifyInstanceAttribute` |
| Check SSM and run guest commands | `ssm:DescribeInstanceInformation`, `ssm:SendCommand`, `ssm:GetCommandInvocation` |
| Optional failed-volume cleanup or manual old-volume deletion | `ec2:DeleteVolume` |

Scope permissions to the appropriate resources, SSM document, and tags where
supported. Organization policies, permission boundaries, endpoint policies, and
KMS key policies must also allow the operations. This is an action inventory,
not a ready-to-attach IAM policy.

For encrypted volumes, authorize use of both the source and replacement KMS keys,
including the grants and cryptographic operations required by EBS. See
[EBS encryption requirements](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption-requirements.html).
The script preserves source encryption and its key unless `--kms-key-id` overrides
the key. Providing a key for an unencrypted source enables encryption; account
encryption defaults may also enable it.

## Quick start

From this directory:

```bash
chmod +x shrink-ebs-root.sh

# Inspect and estimate only; no volume creation or reboot.
./shrink-ebs-root.sh \
  --instance-id i-0123456789abcdef0 --target-size 24 \
  --profile production --region ap-south-1

# Perform the migration; type the instance ID at the confirmation prompt.
./shrink-ebs-root.sh \
  --instance-id i-0123456789abcdef0 --target-size 24 \
  --profile production --region ap-south-1 \
  --stop-services postgresql.service,myapp.service --execute
```

Use real systemd unit names for all application writers. On some installations a
database's umbrella service is not the unit running the database process. Also
quiesce external writers, timers, workers, and orchestration that could restart
services. Do not include SSM Agent or networking services in the stop list.

Preflight is **not offline**: it calls AWS APIs and runs inspection commands via
SSM. Without `--execute`, it exits before creation, attachment, formatting,
service stopping, or root replacement.

## Every argument

Sizes use binary GiB: `1 GiB = 1,073,741,824 bytes`. Options taking a value require
that value as the next argument (`--target-size 24`, not `--target-size=24`).

| Argument | Meaning and default | Example |
| --- | --- | --- |
| `--instance-id ID` | **Required.** Running instance whose root will be replaced, in the selected account and region. | `--instance-id i-0123456789abcdef0` |
| `--target-size GIB` | **Required.** Integer size of the new gp3 disk, 8–2048 GiB for this MBR implementation, strictly smaller than the source EBS volume. This is raw disk size, not usable filesystem capacity. | `--target-size 24` |
| `--region REGION` | Region for all AWS calls. Defaults to normal AWS CLI environment/config resolution. The new disk is created in the instance's Availability Zone. | `--region ap-south-1` |
| `--profile PROFILE` | Named local AWS CLI profile. Omit to use normal CLI credential resolution. | `--profile production` |
| `--stop-services LIST` | Comma-separated systemd units, stopped sequentially before final sync. No spaces. Default: none. Enabled services normally start again after reboot; verify this yourself. Literal `none` explicitly accepts a live final sync. | `--stop-services nginx.service,myapp.service` or `--stop-services none` |
| `--min-free-gib N` | Nonnegative integer usable free-space requirement after copying. Default: `5`. Checked in addition to source usage and the preflight overhead allowance. `0` disables extra headroom, not capacity checks. Allow room for growth and rsync temporary files. | `--min-free-gib 8` |
| `--iops N` | Provisioned gp3 IOPS. Defaults to source IOPS if it is gp3, otherwise `3000`. AWS validates supported values and combinations; increasing performance can increase cost. | `--iops 3000` |
| `--throughput N` | gp3 throughput in MiB/s. Defaults to source throughput if gp3, otherwise `125`. Must be compatible with the selected IOPS and AWS limits. | `--throughput 125` |
| `--kms-key-id KEY` | KMS key ID, ARN, or alias for the new disk. Overrides the source key when encrypted; enables encryption when the source is unencrypted. No decrypt-to-unencrypted option exists. | `--kms-key-id alias/ebs-root` |
| `--execute` | Enable resource creation and migration after preflight. Omit for inspection and a plan only. | `--execute` |
| `--yes` | With `--execute`, skip typing the instance ID. Requires a nonempty `--stop-services` value; `none` explicitly accepts live writers. By itself it does not enable migration. | `--stop-services myapp.service --execute --yes` |
| `--keep-temp-on-failure` | Default. Retain the replacement disk on failure before the switch for investigation or possible resume. It may remain attached/mounted and continues to incur charges. | `--keep-temp-on-failure` |
| `--delete-temp-on-failure` | Attempt to force-detach and delete the replacement on a trapped error before switching. Never deletes the source. Cleanup is best effort and does not run for every exit or interruption; inspect AWS afterward. Avoid this option if you want to resume. | `--delete-temp-on-failure` |
| `--resume` | Reuse the single replacement matching instance/source tags and target size. Requires `--execute` to resume work. Zero matches abort; multiple matches abort instead of choosing the newest. See limitations below. | `--resume --execute` |
| `-h`, `--help` | Print usage and exit without AWS access. | `./shrink-ebs-root.sh --help` |

If both failure-cleanup flags are supplied, the last one wins. Resume reuses the
existing volume; creation options such as IOPS, throughput, and KMS key do not
reconfigure that volume.

### More examples

Larger headroom and explicit gp3 performance, still preflight only:

```bash
./shrink-ebs-root.sh --instance-id i-0123456789abcdef0 --target-size 40 \
  --min-free-gib 8 --iops 3000 --throughput 125
```

Unattended migration using a named encryption key:

```bash
./shrink-ebs-root.sh --instance-id i-0123456789abcdef0 --target-size 32 \
  --region ap-south-1 --profile production --kms-key-id alias/ebs-root \
  --stop-services myapp.service --execute --yes
```

Explicitly accepting a live final copy (only appropriate when workload consistency
is handled separately):

```bash
./shrink-ebs-root.sh --instance-id i-0123456789abcdef0 --target-size 24 \
  --stop-services none --execute --yes
```

Request cleanup of a failed replacement instead of retaining it:

```bash
./shrink-ebs-root.sh --instance-id i-0123456789abcdef0 --target-size 24 \
  --stop-services myapp.service --delete-temp-on-failure --execute
```

## How capacity checks work

1. **Before creating any disk:** the first guest inspection measures allocated
   root filesystem usage with `df -B1 --output=used /`. Preflight compares that
   usage plus `--min-free-gib` against requested disk bytes minus a conservative
   10% allowance for ext4 metadata/reserved blocks and 1 MiB for partition alignment.
2. **Before wiping the attached replacement:** resolve its NVMe device by EBS ID,
   reject the source disk and mounted targets, refresh root usage, and check the
   actual `blockdev --getsize64` size using the same allowance.
3. **After formatting, before the first copy:** refresh source usage and compare
   it plus headroom against the new filesystem's actual `df` available bytes.
   This excludes ext4 reserved blocks; raw EBS capacity alone is not sufficient.
4. **Before final sync, including a resumed sync:** refresh usage again and check
   against target `used + available` bytes. Existing copied data is already part
   of that budget, so it is not counted twice. This check precedes service stopping.
5. **After final sync:** require actual remaining available space to meet the
   configured headroom before proceeding to the root switch.

Insufficient capacity returns a nonzero status and an error with used, usable,
required, and missing bytes. Missing or invalid measurements also abort. For
example, 18 GiB used plus 5 GiB headroom fails for a 24 GiB disk: its preflight
usable estimate is only about 21.6 GiB. A 32 GiB target may fit, provided it is
still smaller than the source and passes the actual filesystem checks.

The estimate is intentionally conservative and can reject a tight fit. It counts
all allocated root usage, including files excluded from copying and deleted files
still held open. `rsync --sparse` avoids unnecessarily allocating zero-filled
regions, but filesystem allocation can still differ. Byte checks cannot guarantee
inode availability or space for concurrent growth and rsync temporary replacement
files. Use headroom appropriate to the workload and stop writers. A copy error
aborts the migration rather than approving the root switch.

## Migration sequence and copied data

1. Inspect EC2, SSM connectivity, guest layout, tools, and capacity; show a plan.
2. After `--execute` and confirmation, create a gp3 disk in the same AZ (or reuse
   a compatible prior disk with `--resume`). Tag migration state on the disk.
3. Attach it as a secondary disk, validate capacity, create an MBR partition and
   ext4 filesystem, mount it at `/mnt/root-shrink-new`, and copy the root files.
4. Rewrite filesystem UUID/PARTUUID references in `fstab` and GRUB defaults,
   install BIOS GRUB, and regenerate and validate its configuration.
5. Stop requested services, perform the final incremental copy with deletion of
   stale target files, check remaining space, and repair boot configuration again.
6. Unmount and run a read-only ext4 consistency check, then perform a further
   bootloader validation before detaching the new volume.
7. Ask EC2 to replace the root with the prepared volume, explicitly retaining the
   old root, and wait for EC2 health checks. Restore the previous root mapping's
   `DeleteOnTermination` setting and tag both volumes.
8. Wait for SSM to reconnect and print root, disk, and failed-service information.
   Validate the application yourself before deleting anything.

Copying uses `rsync -aHAXx --sparse --numeric-ids`: ownership, permissions, hard
links, ACLs, and extended attributes are preserved, and traversal stays on the
root filesystem. Contents under `/dev`, `/proc`, `/sys`, `/run`, `/tmp`, `/mnt`,
and `/media`, plus `/lost+found`, are excluded. **Real application data under
those excluded directories will not be copied.** Separate mounted filesystems
are not copied; arrange their mount points and configuration appropriately.

This is a file-level copy, not a block clone or transactional database backup.
There is an initial live copy followed by the final copy. Stopping only some
writers cannot guarantee application consistency. SSM usually exposes command
output after completion; long rsync operations may appear quiet despite status
messages from the wrapper.

AWS documents the existing-volume replacement mechanism, its same-AZ and detached
volume requirements, and reboot behavior in
[Replace an EC2 root volume](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/replace-root.html).

## Verification, rollback, and deleting the old disk

Save the printed instance ID, old/new volume IDs, and replacement task ID. Inspect
the EC2 root mapping, `findmnt /`, `df -hT /`, application health, logs, databases,
and systemd units after reboot. EC2 health checks alone do not establish application
health. The current script prints a warning if SSM does not reconnect within its
verification window and can still print `SUCCESS`; treat that as incomplete guest
verification and investigate before deleting the old disk.

The retained old disk contains the pre-switch filesystem. It does **not** receive
new writes after the switch. Rolling back can lose or require reconciliation of
post-switch application changes. For a running compatible instance, the EC2
existing-volume replacement operation can switch back to the detached old disk.
For an unbootable instance, use an EC2 recovery procedure to stop it and restore
the old root attachment. The script does not automate rollback.

After your chosen rollback period and application checks, verify the **old** disk
is detached and is not the current root. Use the IDs from your own run:

```bash
aws --profile production --region ap-south-1 ec2 describe-instances \
  --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[0].Instances[0].{Root:RootDeviceName,Mappings:BlockDeviceMappings}'

aws --profile production --region ap-south-1 ec2 describe-volumes \
  --volume-ids vol-OLD_ROOT_ID \
  --query 'Volumes[0].{State:State,Attachments:Attachments,Tags:Tags}'

# Irreversible: run only for the confirmed old, detached rollback disk.
aws --profile production --region ap-south-1 ec2 delete-volume \
  --volume-id vol-OLD_ROOT_ID
```

There is deliberately no automatic old-root deletion flag.

## Failures and resume limitations

Only run one migration per instance at a time; there is no concurrency lock.
Do not start another run while a prior SSM command or root-replacement task is
still running. Interrupting the local script does not necessarily stop remote
work. Inspect the logged SSM command IDs and EC2 task before taking action.

By default, failed replacements remain for investigation. They may still be
mounted; inspect mounts before detaching or deleting them. The script attempts
some service recovery on trapped failures, but it is not a general rollback
manager. In particular, a failure during final sync can leave services stopped.
Check and restart the correct units on the active root as needed.

Resume selection uses `RootShrinkTargetInstance`, `RootShrinkSource`, and size;
`RootShrinkState` controls which stages are skipped. It does not select the
latest by timestamp or validate that creation settings still match your flags.

```bash
./shrink-ebs-root.sh --instance-id i-0123456789abcdef0 --target-size 24 \
  --stop-services myapp.service --keep-temp-on-failure --resume --execute
```

Treat `--resume` as limited recovery for an inspected, compatible pre-switch
replacement. A skipped completed sync can be stale if the original root has
received further writes. Some interrupted states leave mounts or a detached
target requiring manual recovery. Once switching has begun, inspect the existing
EC2 task instead of blindly resuming: the script does not rejoin an existing task
and can submit another replacement request. After a successful switch, the old
migration usually no longer matches because the instance's source volume changed.

## Development

The script is self-contained. Local tests use Python 3's standard library and
mocked disk/AWS responses; they do not contact AWS or modify disks:

```bash
bash -n shrink-ebs-root.sh
python3 -m unittest discover -s tests -v
```

An actual migration still needs validation on a disposable EC2 instance matching
the supported layout. Local tests cannot establish bootability or application
consistency.

## License

MIT. See [LICENSE](LICENSE).
