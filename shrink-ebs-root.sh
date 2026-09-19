#!/usr/bin/env bash
set -Eeuo pipefail

# shrink-ebs-root.sh
# Safely replaces a supported EC2 root EBS volume with a smaller gp3 volume.
# v1 intentionally supports only the layout validated for this fleet pattern:
#   - Linux EC2 instance managed by SSM
#   - EBS root volume
#   - Legacy BIOS boot
#   - DOS/MBR partition table
#   - exactly one root partition
#   - ext4 root filesystem
#   - no LVM/RAID/device-mapper root
#
# It does NOT shrink the source filesystem. It creates a new smaller volume,
# copies the filesystem, installs GRUB, then uses EC2 root-volume replacement.
# The original root volume is retained for rollback.

VERSION="1.4.0"
AWS_PAGER=""
export AWS_PAGER

usage() {
  cat <<'USAGE'
Usage:
  shrink-ebs-root.sh --instance-id i-... --target-size GIB [options]

Required:
  --instance-id ID          EC2 instance ID
  --target-size GIB         New root volume size in GiB

Options:
  --region REGION           AWS region (otherwise AWS CLI config is used)
  --profile PROFILE         AWS CLI profile
  --stop-services LIST      Comma-separated systemd units to stop before final sync
                            Example: postgresql,nginx,myapp.service
  --min-free-gib N          Require N GiB usable free space after copying (default: 5)
  --iops N                  gp3 IOPS (default: source IOPS if gp3, otherwise 3000)
  --throughput N            gp3 throughput MiB/s (default: source throughput if gp3, otherwise 125)
  --kms-key-id KEY          Use this KMS key; also enables encryption for an unencrypted source
  --execute                 Actually perform the migration. Without this, only preflight/plan.
  --yes                     Skip the final interactive confirmation (requires --execute)
  --keep-temp-on-failure    Retain replacement volume after a pre-switch failure (default)
  --delete-temp-on-failure  Delete replacement volume after a pre-switch failure
  --resume                  Resume the single compatible prior migration for this instance
  -h, --help                Show help

Examples:
  # Preflight only
  ./shrink-ebs-root.sh --instance-id i-0123456789abcdef0 --target-size 24

  # Execute, stopping application writers before the final rsync
  ./shrink-ebs-root.sh --instance-id i-0123456789abcdef0 --target-size 24 \
      --stop-services postgresql,myapp.service --execute

Safety:
  * The old root EBS volume is never deleted by this script.
  * Unsupported disk layouts cause an abort before a replacement disk is created.
  * The replacement volume is prepared while attached as a secondary disk.
  * Root replacement is done using EC2 CreateReplaceRootVolumeTask.
USAGE
}

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
step() { printf '\n[%s] ============================================================\n[%s] STEP: %s\n[%s] ============================================================\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$(date '+%Y-%m-%d %H:%M:%S')"; }
detail() { printf '[%s]   -> %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

# Shared locally and in SSM payloads; fail closed on missing/invalid measurements.
check_capacity() {
  local used="$1" capacity="$2" headroom="$3" context="$4" value required
  for value in "$used" "$capacity" "$headroom"; do
    if [[ ! "$value" =~ ^[0-9]{1,16}$ ]]; then
      printf 'ERROR: %s: invalid capacity measurement: %s; aborting.\n' "$context" "$value" >&2
      return 1
    fi
  done
  used=$((10#$used)); capacity=$((10#$capacity)); headroom=$((10#$headroom))
  required=$((used + headroom))
  printf '[capacity] %s: source used=%s bytes, target usable=%s bytes, required headroom=%s bytes\n' \
    "$context" "$used" "$capacity" "$headroom"
  if (( capacity < required )); then
    printf 'ERROR: %s: insufficient target space: source uses %s bytes + headroom %s bytes = %s bytes required, but target has %s usable bytes (short by %s bytes). Choose a larger --target-size or free source space; aborting.\n' \
      "$context" "$used" "$headroom" "$required" "$capacity" "$((required - capacity))" >&2
    return 1
  fi
}

# Before mkfs, budget 10% for ext4 metadata/reserved blocks plus 1 MiB alignment.
# This is an estimate; df on the formatted filesystem is authoritative.
estimated_capacity() {
  local bytes="$1"
  [[ "$bytes" =~ ^[0-9]{1,16}$ ]] && (( 10#$bytes > 1048576 )) || {
    echo 'ERROR: invalid target disk size; aborting.' >&2
    return 1
  }
  printf '%s\n' "$((10#$bytes - 10#$bytes / 10 - 1048576))"
}

# The existing target data is included in its total usable budget on a resync.
# Never add the source data to target used data: that would double-count the copy.
check_guest_capacity() {
  local target="$1" mode="$2" headroom="$3" used capacity target_used target_avail
  used=$(df -B1 --output=used / | awk 'NR==2 {print $1}') || return 1
  if [[ "$mode" == raw ]]; then
    capacity=$(blockdev --getsize64 "$target") || return 1
    capacity=$(estimated_capacity "$capacity") || return 1
  else
    read -r target_used target_avail <<< "$(df -B1 --output=used,avail "$target" | awk 'NR==2 {print $1, $2}')"
    [[ "$target_used" =~ ^[0-9]{1,16}$ && "$target_avail" =~ ^[0-9]{1,16}$ ]] || {
      echo 'ERROR: cannot measure usable target filesystem space; aborting.' >&2
      return 1
    }
    if [[ "$mode" == empty-filesystem ]]; then
      capacity=$((10#$target_avail))
    else
      capacity=$((10#$target_used + 10#$target_avail))
    fi
  fi
  check_capacity "$used" "$capacity" "$headroom" "$mode target $target"
}

INSTANCE_ID=""
TARGET_SIZE=""
REGION=""
PROFILE=""
STOP_SERVICES=""
MIN_FREE_GIB=5
IOPS=""
THROUGHPUT=""
KMS_KEY_ID=""
EXECUTE=0
ASSUME_YES=0
KEEP_TEMP_ON_FAILURE=1
RESUME=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="${2:?}"; shift 2 ;;
    --target-size) TARGET_SIZE="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --stop-services) STOP_SERVICES="${2:?}"; shift 2 ;;
    --min-free-gib) MIN_FREE_GIB="${2:?}"; shift 2 ;;
    --iops) IOPS="${2:?}"; shift 2 ;;
    --throughput) THROUGHPUT="${2:?}"; shift 2 ;;
    --kms-key-id) KMS_KEY_ID="${2:?}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --keep-temp-on-failure) KEEP_TEMP_ON_FAILURE=1; shift ;;
    --delete-temp-on-failure) KEEP_TEMP_ON_FAILURE=0; shift ;;
    --resume) RESUME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE_ID" ]] || { usage; die "--instance-id is required"; }
[[ "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]] || die "Invalid EC2 instance ID: $INSTANCE_ID"
[[ "$TARGET_SIZE" =~ ^[0-9]+$ ]] || die "--target-size must be an integer GiB value"
[[ ${#TARGET_SIZE} -le 4 ]] || die "--target-size exceeds supported DOS/MBR capacity"
TARGET_SIZE=$((10#$TARGET_SIZE))
[[ "$TARGET_SIZE" -ge 8 ]] || die "Refusing target smaller than 8 GiB"
[[ "$TARGET_SIZE" -le 2048 ]] || die "--target-size exceeds supported DOS/MBR capacity (2048 GiB)"
[[ "$MIN_FREE_GIB" =~ ^[0-9]+$ ]] || die "--min-free-gib must be an integer"
[[ ${#MIN_FREE_GIB} -le 4 ]] || die "--min-free-gib exceeds supported target capacity"
MIN_FREE_GIB=$((10#$MIN_FREE_GIB))

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

AWS=(aws)
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")
[[ -n "$REGION" ]] && AWS+=(--region "$REGION")

awsj() { "${AWS[@]}" "$@" --output json; }
awst() { "${AWS[@]}" "$@" --output text; }

# Verify the installed CLI exposes --volume-id for root replacement.
if ! "${AWS[@]}" ec2 create-replace-root-volume-task --generate-cli-skeleton input 2>/dev/null | grep -q 'VolumeId'; then
  die "Installed AWS CLI does not expose EC2 root replacement with an existing --volume-id. Upgrade AWS CLI v2."
fi

step "PRE-FLIGHT: Inspect EC2 instance and source EBS volume"
detail "Instance ID: $INSTANCE_ID"
detail "Requested target size: ${TARGET_SIZE} GiB"
log "Inspecting $INSTANCE_ID"
INST_JSON="$(awsj ec2 describe-instances --instance-ids "$INSTANCE_ID")"
STATE="$(jq -r '.Reservations[0].Instances[0].State.Name // empty' <<<"$INST_JSON")"
[[ "$STATE" == "running" ]] || die "Instance must be running; current state: ${STATE:-unknown}"

AZ="$(jq -r '.Reservations[0].Instances[0].Placement.AvailabilityZone' <<<"$INST_JSON")"
INSTANCE_TYPE="$(jq -r '.Reservations[0].Instances[0].InstanceType' <<<"$INST_JSON")"
ROOT_DEV="$(jq -r '.Reservations[0].Instances[0].RootDeviceName' <<<"$INST_JSON")"
ROOT_TYPE="$(jq -r '.Reservations[0].Instances[0].RootDeviceType' <<<"$INST_JSON")"
[[ "$ROOT_TYPE" == "ebs" ]] || die "Root device is not EBS-backed"

ROOT_VOL="$(jq -r --arg dev "$ROOT_DEV" '.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.DeviceName==$dev) | .Ebs.VolumeId' <<<"$INST_JSON")"
DELETE_ON_TERMINATION="$(jq -r --arg dev "$ROOT_DEV" '.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.DeviceName==$dev) | .Ebs.DeleteOnTermination' <<<"$INST_JSON")"
[[ "$ROOT_VOL" == vol-* ]] || die "Could not resolve root EBS volume"

VOL_JSON="$(awsj ec2 describe-volumes --volume-ids "$ROOT_VOL")"
SOURCE_SIZE="$(jq -r '.Volumes[0].Size' <<<"$VOL_JSON")"
SOURCE_TYPE="$(jq -r '.Volumes[0].VolumeType' <<<"$VOL_JSON")"
SOURCE_IOPS="$(jq -r '.Volumes[0].Iops // 0' <<<"$VOL_JSON")"
SOURCE_TPUT="$(jq -r '.Volumes[0].Throughput // 0' <<<"$VOL_JSON")"
SOURCE_ENCRYPTED="$(jq -r '.Volumes[0].Encrypted' <<<"$VOL_JSON")"
SOURCE_KMS="$(jq -r '.Volumes[0].KmsKeyId // empty' <<<"$VOL_JSON")"

(( TARGET_SIZE < SOURCE_SIZE )) || die "Target (${TARGET_SIZE} GiB) must be smaller than source (${SOURCE_SIZE} GiB)"

if [[ -z "$IOPS" ]]; then
  if [[ "$SOURCE_TYPE" == "gp3" ]]; then IOPS="$SOURCE_IOPS"; else IOPS=3000; fi
fi
if [[ -z "$THROUGHPUT" ]]; then
  if [[ "$SOURCE_TYPE" == "gp3" ]]; then THROUGHPUT="$SOURCE_TPUT"; else THROUGHPUT=125; fi
fi

# SSM must already manage the instance.
PING="$(awst ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[0].PingStatus' 2>/dev/null || true)"
[[ "$PING" == "Online" ]] || die "Instance is not Online in AWS Systems Manager (SSM)."

ssm_run() {
  local comment="$1"
  local script="$2"
  local timeout="${3:-3600}"
  local params cmdid status out err started now elapsed last_status="" encoded wrapped

  # AWS-RunShellScript launches commands through /bin/sh on Ubuntu.  The guest
  # payloads in this tool intentionally use Bash features (pipefail, [[ ]], etc.),
  # so encode the complete payload and explicitly feed it to bash.  Base64 avoids
  # fragile nested quoting for multiline scripts sent through SSM.
  encoded="$(printf '%s' "$script" | base64 | tr -d '\n')"
  wrapped="printf '%s' '$encoded' | base64 -d | bash"
  params="$(jq -cn --arg s "$wrapped" '{commands:[$s]}')"
  log "SSM: submitting command via explicit bash: $comment"
  cmdid="$(awst ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "$comment" \
    --timeout-seconds "$timeout" \
    --parameters "$params" \
    --query 'Command.CommandId')"
  detail "SSM command ID: $cmdid (timeout ${timeout}s)"
  started=$(date +%s)

  while :; do
    status="$(awst ssm get-command-invocation --command-id "$cmdid" --instance-id "$INSTANCE_ID" --query Status 2>/dev/null || true)"
    now=$(date +%s); elapsed=$((now-started))
    if [[ "$status" != "$last_status" ]]; then
      log "SSM [$cmdid] status=$status elapsed=${elapsed}s"
      last_status="$status"
    elif (( elapsed % 15 < 3 )); then
      log "SSM [$cmdid] still $status ... elapsed=${elapsed}s"
    fi
    case "$status" in
      Success) log "SSM [$cmdid] completed successfully in ${elapsed}s"; break ;;
      Failed|Cancelled|TimedOut|Cancelling)
        out="$(awst ssm get-command-invocation --command-id "$cmdid" --instance-id "$INSTANCE_ID" --query StandardOutputContent 2>/dev/null || true)"
        err="$(awst ssm get-command-invocation --command-id "$cmdid" --instance-id "$INSTANCE_ID" --query StandardErrorContent 2>/dev/null || true)"
        [[ -n "$out" && "$out" != "None" ]] && printf '%s\n' "$out" >&2
        [[ -n "$err" && "$err" != "None" ]] && printf '%s\n' "$err" >&2
        die "SSM command failed: $comment (status=$status)"
        ;;
      *) sleep 3 ;;
    esac
  done
  awst ssm get-command-invocation --command-id "$cmdid" --instance-id "$INSTANCE_ID" --query StandardOutputContent
}

PREFLIGHT_SCRIPT='set -Eeuo pipefail
ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_PART=$(readlink -f "$ROOT_SRC")
ROOT_FS=$(findmnt -n -o FSTYPE /)
[[ "$ROOT_PART" == /dev/* ]] || { echo "FAIL=root source is not a block device: $ROOT_SRC"; exit 20; }
PK=$(lsblk -n -o PKNAME "$ROOT_PART" | head -n1)
[[ -n "$PK" ]] || { echo "FAIL=cannot determine parent root disk"; exit 21; }
ROOT_DISK="/dev/$PK"
PTTYPE=$(lsblk -dn -o PTTYPE "$ROOT_DISK")
PARTTYPE=$(lsblk -n -o TYPE "$ROOT_PART")
PARTCOUNT=$(lsblk -n -o TYPE "$ROOT_DISK" | awk '\''$1=="part"{n++} END{print n+0}'\'')
BOOTMODE=legacy
[[ -d /sys/firmware/efi ]] && BOOTMODE=uefi
USED=$(df -B1 --output=used / | tail -n1 | tr -d " ")
TOTAL=$(df -B1 --output=size / | tail -n1 | tr -d " ")
AVAIL=$(df -B1 --output=avail / | tail -n1 | tr -d " ")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
ROOT_LABEL=$(blkid -s LABEL -o value "$ROOT_PART" || true)
ROOT_PARTNUM=""
if [[ -r "/sys/class/block/$(basename "$ROOT_PART")/partition" ]]; then
  ROOT_PARTNUM=$(cat "/sys/class/block/$(basename "$ROOT_PART")/partition")
else
  ROOT_PARTNUM=$(basename "$ROOT_PART" | grep -oE "[0-9]+$")
fi
ROOT_MAJMIN=$(lsblk -n -o MAJ:MIN "$ROOT_PART" | head -n1)
LVM=0
command -v pvs >/dev/null 2>&1 && pvs --noheadings 2>/dev/null | grep -q . && LVM=1 || true
RAID=0
[[ -e /proc/mdstat ]] && grep -q "^md[0-9]" /proc/mdstat && RAID=1 || true
for c in rsync sfdisk mkfs.ext4 grub-install update-grub findmnt lsblk blkid blockdev df wipefs partprobe udevadm e2fsck mount umount mountpoint chroot systemctl; do command -v "$c" >/dev/null || { echo "FAIL=missing command: $c"; exit 22; }; done
printf "ROOT_SRC=%s\nROOT_PART=%s\nROOT_DISK=%s\nROOT_FS=%s\nPTTYPE=%s\nPARTCOUNT=%s\nBOOTMODE=%s\nUSED_BYTES=%s\nTOTAL_BYTES=%s\nAVAIL_BYTES=%s\nROOT_UUID=%s\nROOT_LABEL=%s\nROOT_PARTNUM=%s\nLVM=%s\nRAID=%s\n" "$ROOT_SRC" "$ROOT_PART" "$ROOT_DISK" "$ROOT_FS" "$PTTYPE" "$PARTCOUNT" "$BOOTMODE" "$USED" "$TOTAL" "$AVAIL" "$ROOT_UUID" "$ROOT_LABEL" "$ROOT_PARTNUM" "$LVM" "$RAID"'

step "PRE-FLIGHT: Inspect guest OS, filesystem, partition table and boot mode"
log "Running guest preflight through SSM"
PREFLIGHT="$(ssm_run "root shrink preflight" "$PREFLIGHT_SCRIPT" 300)"
printf '%s\n' "$PREFLIGHT" | grep -q '^FAIL=' && die "Guest preflight failed: $PREFLIGHT"

get_pf() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' <<<"$PREFLIGHT"; }
ROOT_FS="$(get_pf ROOT_FS)"
PTTYPE="$(get_pf PTTYPE)"
PARTCOUNT="$(get_pf PARTCOUNT)"
BOOTMODE="$(get_pf BOOTMODE)"
USED_BYTES="$(get_pf USED_BYTES)"
LVM="$(get_pf LVM)"
RAID="$(get_pf RAID)"
ROOT_PARTNUM="$(get_pf ROOT_PARTNUM)"

[[ "$ROOT_FS" == "ext4" ]] || die "Unsupported root filesystem: $ROOT_FS (v1 supports ext4 only)"
[[ "$PTTYPE" == "dos" ]] || die "Unsupported partition table: $PTTYPE (v1 supports DOS/MBR only)"
[[ "$BOOTMODE" == "legacy" ]] || die "Unsupported boot mode: $BOOTMODE (v1 supports Legacy BIOS only)"
[[ "$PARTCOUNT" == "1" ]] || die "Unsupported root-disk layout: expected exactly 1 partition, found $PARTCOUNT"
[[ "$ROOT_PARTNUM" == "1" ]] || die "Unsupported root partition number: $ROOT_PARTNUM"
[[ "$LVM" == "0" ]] || die "LVM detected; refusing automated migration"
[[ "$RAID" == "0" ]] || die "mdraid detected; refusing automated migration"

TARGET_BYTES=$(( TARGET_SIZE * 1024 * 1024 * 1024 ))
MIN_FREE_BYTES=$(( MIN_FREE_GIB * 1024 * 1024 * 1024 ))
step "PRE-FLIGHT: Check current root usage against target capacity"
ESTIMATED_USABLE_BYTES=$(estimated_capacity "$TARGET_BYTES")
check_capacity "$USED_BYTES" "$ESTIMATED_USABLE_BYTES" "$MIN_FREE_BYTES" "requested ${TARGET_SIZE} GiB volume (estimated usable space)" || exit 1

USED_GIB="$(awk -v b="$USED_BYTES" 'BEGIN{printf "%.1f", b/1024/1024/1024}')"
EXPECTED_FREE_GIB="$(awk -v t="$ESTIMATED_USABLE_BYTES" -v u="$USED_BYTES" 'BEGIN{printf "%.1f", (t-u)/1024/1024/1024}')"

cat <<PLAN

Preflight passed
----------------
Instance:                  $INSTANCE_ID ($INSTANCE_TYPE)
Availability Zone:         $AZ
Root device mapping:       $ROOT_DEV
Current root volume:       $ROOT_VOL
Current EBS size/type:     ${SOURCE_SIZE} GiB / $SOURCE_TYPE
Root filesystem:           ext4
Partition table / boot:    DOS/MBR / Legacy BIOS
Root layout:               single partition
Current used data:         ~${USED_GIB} GiB
Requested replacement:     ${TARGET_SIZE} GiB gp3
Estimated usable free:    ~${EXPECTED_FREE_GIB} GiB (actual filesystem checked before copy)
Replacement IOPS:          $IOPS
Replacement throughput:    ${THROUGHPUT} MiB/s
Source encrypted:          $SOURCE_ENCRYPTED
Old root delete-on-term:   $DELETE_ON_TERMINATION
Services to stop:          ${STOP_SERVICES:-<none>}
Old root after migration:  RETAINED for rollback
PLAN

step "PRE-FLIGHT COMPLETE"
if [[ "$EXECUTE" -eq 0 ]]; then
  log "Preflight only. Re-run with --execute when ready."
  exit 0
fi

if [[ -z "$STOP_SERVICES" ]]; then
  warn "No --stop-services supplied. The final rsync will occur while applications may still be writing."
  warn "For databases/stateful services, explicitly pass their systemd units."
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    die "--yes with --execute requires --stop-services for safety. Pass a list, or use --stop-services none if you intentionally accept a live final sync."
  fi
fi

if [[ "$STOP_SERVICES" == "none" ]]; then STOP_SERVICES=""; fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  printf '\nThis will create and prepare a new EBS volume and ultimately reboot %s.\n' "$INSTANCE_ID"
  read -r -p "Type the instance ID to continue: " confirm
  [[ "$confirm" == "$INSTANCE_ID" ]] || die "Confirmation did not match; aborting"
fi

NEW_VOL=""
SWITCH_STARTED=0
SERVICES_STOPPED=0

cleanup_on_error() {
  local rc=$?
  if (( rc == 0 )); then return; fi
  warn "Migration exited with error code $rc"

  if (( SERVICES_STOPPED == 1 && SWITCH_STARTED == 0 )); then
    warn "Attempting to restart services on the original root"
    if [[ -n "$STOP_SERVICES" ]]; then
      RESTART_SCRIPT="set +e; systemctl start ${STOP_SERVICES//,/ }"
      ssm_run "restart services after root-shrink failure" "$RESTART_SCRIPT" 300 >/dev/null || true
    fi
  fi

  if [[ -n "$NEW_VOL" && "$SWITCH_STARTED" -eq 0 && "$KEEP_TEMP_ON_FAILURE" -eq 0 ]]; then
    warn "Attempting to detach/delete temporary replacement volume $NEW_VOL"
    "${AWS[@]}" ec2 detach-volume --volume-id "$NEW_VOL" --force >/dev/null 2>&1 || true
    log "Waiting for $NEW_VOL to become available"
"${AWS[@]}" ec2 wait volume-available --volume-ids "$NEW_VOL"
log "$NEW_VOL is available" >/dev/null 2>&1 || true
    "${AWS[@]}" ec2 delete-volume --volume-id "$NEW_VOL" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup_on_error ERR


# Durable migration state is stored on the replacement EBS volume so a failed
# local wrapper can safely resume without relying on truncated SSM stdout.
set_state() {
  local state="$1"
  [[ -n "${NEW_VOL:-}" ]] || return 0
  "${AWS[@]}" ec2 create-tags --resources "$NEW_VOL" --tags \
    Key=RootShrinkState,Value="$state" \
    Key=RootShrinkTargetInstance,Value="$INSTANCE_ID" \
    Key=RootShrinkSource,Value="$ROOT_VOL" \
    Key=RootShrinkTargetSize,Value="$TARGET_SIZE" \
    Key=RootShrinkScriptVersion,Value="$VERSION" >/dev/null
  log "Persisted migration state on $NEW_VOL: $state"
}

find_resume_volume() {
  local vols count
  vols="$(awst ec2 describe-volumes \
    --filters \
      "Name=tag:RootShrinkTargetInstance,Values=$INSTANCE_ID" \
      "Name=tag:RootShrinkSource,Values=$ROOT_VOL" \
    --query "Volumes[?Size==\`${TARGET_SIZE}\`].VolumeId" 2>/dev/null || true)"
  count=$(wc -w <<<"$vols" | tr -d ' ')
  [[ "$count" -eq 1 ]] || { [[ "$count" -eq 0 ]] && return 1; die "Multiple compatible resumable replacement volumes found: $vols"; }
  printf '%s\n' "$vols"
}
get_volume_state_tag() {
  awst ec2 describe-volumes --volume-ids "$1" --query 'Volumes[0].Tags[?Key==`RootShrinkState`].Value | [0]' 2>/dev/null || true
}

CREATE_ARGS=(ec2 create-volume --availability-zone "$AZ" --size "$TARGET_SIZE" --volume-type gp3 --iops "$IOPS" --throughput "$THROUGHPUT")
if [[ "$SOURCE_ENCRYPTED" == "true" ]]; then
  CREATE_ARGS+=(--encrypted)
  EFFECTIVE_KMS="${KMS_KEY_ID:-$SOURCE_KMS}"
  [[ -n "$EFFECTIVE_KMS" ]] && CREATE_ARGS+=(--kms-key-id "$EFFECTIVE_KMS")
elif [[ -n "$KMS_KEY_ID" ]]; then
  CREATE_ARGS+=(--encrypted --kms-key-id "$KMS_KEY_ID")
fi
CREATE_ARGS+=(--tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=root-shrink-${INSTANCE_ID}},{Key=RootShrinkSource,Value=${ROOT_VOL}},{Key=RootShrinkTargetInstance,Value=${INSTANCE_ID}}]")

step "1/8: Resolve or create replacement EBS volume"
MIGRATION_STATE=""
if [[ "$RESUME" -eq 1 ]]; then
  NEW_VOL="$(find_resume_volume || true)"
  [[ "$NEW_VOL" == vol-* ]] || die "--resume requested but no compatible prior replacement volume was found"
  MIGRATION_STATE="$(get_volume_state_tag "$NEW_VOL")"
  if [[ -z "$MIGRATION_STATE" || "$MIGRATION_STATE" == "None" ]]; then
    warn "Replacement volume predates durable state tags; probing its guest layout before deciding where to resume"
    LEGACY_SERIAL="${NEW_VOL//-/}"
    PROBE_SCRIPT=$(cat <<EOFPROBE
set -Eeuo pipefail
SERIAL='$LEGACY_SERIAL'
for sys in /sys/block/nvme*n1; do
  [[ -e "\$sys" ]] || continue
  s=\$(tr -d ' ' < "\$sys/device/serial" 2>/dev/null || true)
  if [[ "\$s" == "\$SERIAL" ]]; then
    d="/dev/\$(basename "\$sys")"
    p="\${d}p1"
    if [[ -b "\$p" ]] && [[ "\$(blkid -s TYPE -o value "\$p" 2>/dev/null || true)" == ext4 ]]; then
      echo LEGACY_STAGE=prepared
    else
      echo LEGACY_STAGE=attached
    fi
    exit 0
  fi
done
echo LEGACY_STAGE=not-attached
EOFPROBE
)
    PROBE_OUT="$(ssm_run "probe legacy root-shrink volume $NEW_VOL" "$PROBE_SCRIPT" 300)"
    if grep -q '^LEGACY_STAGE=prepared' <<<"$PROBE_OUT"; then
      MIGRATION_STATE=prepared
      set_state prepared
    elif grep -q '^LEGACY_STAGE=attached' <<<"$PROBE_OUT"; then
      MIGRATION_STATE=attached
      set_state attached
    else
      MIGRATION_STATE=created
      set_state created
    fi
  fi
  log "Resuming migration using $NEW_VOL (state=${MIGRATION_STATE:-unknown})"
else
  detail "AZ=$AZ type=gp3 size=${TARGET_SIZE}GiB IOPS=$IOPS throughput=${THROUGHPUT}MiB/s encrypted=$SOURCE_ENCRYPTED"
  log "Creating ${TARGET_SIZE} GiB gp3 replacement volume in $AZ"
  NEW_VOL="$(awst "${CREATE_ARGS[@]}" --query VolumeId)"
  [[ "$NEW_VOL" == vol-* ]] || die "Could not create replacement volume"
  log "Created $NEW_VOL"
  "${AWS[@]}" ec2 wait volume-available --volume-ids "$NEW_VOL"
  set_state created
  MIGRATION_STATE=created
fi

if [[ "$MIGRATION_STATE" != "prepared" && "$MIGRATION_STATE" != "final-sync-complete" && "$MIGRATION_STATE" != "switch-started" && "$MIGRATION_STATE" != "active" ]]; then
  step "2/8: Attach replacement volume to source instance"
  VOL_STATE="$(awst ec2 describe-volumes --volume-ids "$NEW_VOL" --query 'Volumes[0].State')"
  if [[ "$VOL_STATE" == "available" ]]; then
    log "Attaching $NEW_VOL temporarily as /dev/sdf"
    awsj ec2 attach-volume --volume-id "$NEW_VOL" --instance-id "$INSTANCE_ID" --device /dev/sdf >/dev/null
    log "Waiting for $NEW_VOL attachment to become in-use"
    "${AWS[@]}" ec2 wait volume-in-use --volume-ids "$NEW_VOL"
  else
    log "$NEW_VOL is already attached/in-use; continuing"
  fi
  set_state attached
  MIGRATION_STATE=attached
else
  log "Skipping attachment/preparation setup because durable state is $MIGRATION_STATE"
fi

NEW_SERIAL="${NEW_VOL//-/}"
PREP_SCRIPT=$(cat <<EOF2
set -Eeuo pipefail
echo '[guest] Starting replacement disk preparation'
$(declare -f check_capacity estimated_capacity check_guest_capacity)
VOL_ID='$NEW_VOL'
VOL_SERIAL='$NEW_SERIAL'
MNT=/mnt/root-shrink-new

find_target_disk() {
  local sys serial name
  for sys in /sys/block/nvme*n1; do
    [[ -e "\$sys" ]] || continue
    serial=\$(tr -d ' ' < "\$sys/device/serial" 2>/dev/null || true)
    if [[ "\$serial" == "\$VOL_SERIAL" ]]; then
      name=\$(basename "\$sys")
      echo "/dev/\$name"
      return 0
    fi
  done
  if [[ -e "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_\$VOL_SERIAL" ]]; then
    readlink -f "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_\$VOL_SERIAL"
    return 0
  fi
  return 1
}

echo "[guest] Locating NVMe device for EBS volume \$VOL_ID"
DST=\$(find_target_disk) || { echo "Cannot locate NVMe device for \$VOL_ID"; exit 30; }
echo "[guest] Replacement device resolved as \$DST"
SRC_PART=\$(readlink -f "\$(findmnt -n -o SOURCE /)")
SRC_PK=\$(lsblk -n -o PKNAME "\$SRC_PART" | head -n1)
SRC_DISK="/dev/\$SRC_PK"
[[ "\$DST" != "\$SRC_DISK" ]] || { echo "Target resolved to source disk; aborting"; exit 31; }
[[ -z "\$(lsblk -n -o MOUNTPOINTS "\$DST" | grep -v '^\s*\$' || true)" ]] || { echo "Target has mounted content; aborting"; exit 32; }
check_guest_capacity "\$DST" raw '$MIN_FREE_BYTES'

# Fresh MBR with one bootable Linux partition spanning the disk.
echo "[guest] Creating fresh DOS/MBR partition table and bootable Linux partition"
wipefs -a "\$DST"
printf ',,83,*\n' | sfdisk "\$DST"
partprobe "\$DST" || true
udevadm settle
if [[ "\$DST" == /dev/nvme* ]]; then DST_PART="\${DST}p1"; else DST_PART="\${DST}1"; fi
for _ in {1..20}; do [[ -b "\$DST_PART" ]] && break; sleep 1; done
[[ -b "\$DST_PART" ]] || { echo "New partition not visible: \$DST_PART"; exit 33; }

SRC_LABEL=\$(blkid -s LABEL -o value "\$SRC_PART" || true)
echo "[guest] Formatting \$DST_PART as ext4"
if [[ -n "\$SRC_LABEL" ]]; then
  mkfs.ext4 -F -L "\$SRC_LABEL" "\$DST_PART"
else
  mkfs.ext4 -F "\$DST_PART"
fi

mkdir -p "\$MNT"
mount "\$DST_PART" "\$MNT"
echo "[guest] Mounted replacement root at \$MNT"
check_guest_capacity "\$MNT" empty-filesystem '$MIN_FREE_BYTES'
echo "[guest] Initial filesystem copy starting. rsync progress follows:"

RSYNC_EXCLUDES=(
  --exclude=/dev/*
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/run/*
  --exclude=/tmp/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
)
rsync -aHAXx --sparse --numeric-ids --info=progress2,stats2 "\${RSYNC_EXCLUDES[@]}" / "\$MNT/"
echo "[guest] Initial filesystem copy complete"
mkdir -p "\$MNT"/{dev,proc,sys,run,tmp,mnt,media}
chmod 1777 "\$MNT/tmp"

SRC_UUID=\$(blkid -s UUID -o value "\$SRC_PART")
DST_UUID=\$(blkid -s UUID -o value "\$DST_PART")
SRC_PARTUUID=\$(blkid -s PARTUUID -o value "\$SRC_PART" || true)
DST_PARTUUID=\$(blkid -s PARTUUID -o value "\$DST_PART" || true)
[[ -n "\$DST_PARTUUID" ]] || { echo "Cannot determine PARTUUID for \$DST_PART"; exit 34; }

echo "[guest] Source PARTUUID: \$SRC_PARTUUID"
echo "[guest] Target PARTUUID: \$DST_PARTUUID"

# Rewrite stable identifiers if fstab pins the old filesystem or partition.
if [[ -f "\$MNT/etc/fstab" ]]; then
  sed -i "s/\$SRC_UUID/\$DST_UUID/g" "\$MNT/etc/fstab"
  if [[ -n "\$SRC_PARTUUID" ]]; then
    sed -i "s/\$SRC_PARTUUID/\$DST_PARTUUID/g" "\$MNT/etc/fstab"
  fi
fi

# Ubuntu AWS cloud images can force the kernel root device through
# /etc/default/grub.d/40-force-partuuid.cfg.  rsync copies the source value,
# so it must be rewritten before update-grub.
echo "[guest] Rewriting GRUB_FORCE_PARTUUID to target PARTUUID"
while IFS= read -r cfg; do
  [[ -n "\$cfg" ]] || continue
  echo "[guest] Updating \$cfg"
  sed -i -E "s|^GRUB_FORCE_PARTUUID=.*$|GRUB_FORCE_PARTUUID=\$DST_PARTUUID|" "\$cfg"
done < <(
  grep -Rl '^GRUB_FORCE_PARTUUID=' \
    "\$MNT/etc/default/grub" \
    "\$MNT/etc/default/grub.d" 2>/dev/null || true
)

# Install GRUB for Legacy BIOS onto the new disk, using the new root filesystem.
echo "[guest] Installing GRUB for Legacy BIOS onto \$DST"
mount --rbind /dev "\$MNT/dev"
mount --make-rslave "\$MNT/dev"
mount -t proc proc "\$MNT/proc"
mount --rbind /sys "\$MNT/sys"
mount --make-rslave "\$MNT/sys"
mount --rbind /run "\$MNT/run"
mount --make-rslave "\$MNT/run"

cleanup_chroot_mounts() {
  umount -R "\$MNT/run" 2>/dev/null || true
  umount -R "\$MNT/sys" 2>/dev/null || true
  umount -R "\$MNT/proc" 2>/dev/null || true
  umount -R "\$MNT/dev" 2>/dev/null || true
}
trap cleanup_chroot_mounts EXIT

chroot "\$MNT" grub-install --target=i386-pc --recheck "\$DST"
chroot "\$MNT" update-grub

echo "[guest] Verifying GRUB uses target PARTUUID"
grep -q "root=PARTUUID=\$DST_PARTUUID" "\$MNT/boot/grub/grub.cfg" || {
  echo "Generated grub.cfg does not reference target PARTUUID \$DST_PARTUUID"
  exit 35
}

if grep -Rh '^GRUB_FORCE_PARTUUID=' \
    "\$MNT/etc/default/grub" "\$MNT/etc/default/grub.d" 2>/dev/null \
    | grep -qv "=\$DST_PARTUUID\$"; then
  echo "Stale GRUB_FORCE_PARTUUID remains after rewrite"
  exit 36
fi

cleanup_chroot_mounts
trap - EXIT

sync
echo "[guest] Disk preparation and bootloader setup complete"
printf 'TARGET_DISK=%s\nTARGET_PART=%s\nTARGET_UUID=%s\nTARGET_PARTUUID=%s\n' "\$DST" "\$DST_PART" "\$DST_UUID" "\$DST_PARTUUID"
EOF2
)

if [[ "$MIGRATION_STATE" != "prepared" && "$MIGRATION_STATE" != "final-sync-complete" && "$MIGRATION_STATE" != "switch-started" && "$MIGRATION_STATE" != "active" ]]; then
  step "3/8: Partition, format, clone root filesystem, and install GRUB"
  warn "This is normally the longest stage. SSM only returns command output after completion, so live rsync lines may not stream to this terminal."
  log "Partitioning, formatting, cloning, and installing GRUB on $NEW_VOL"
  PREP_OUT="$(ssm_run "prepare smaller replacement root $NEW_VOL" "$PREP_SCRIPT" 7200)"
  printf '%s\n' "$PREP_OUT"
  set_state prepared
  MIGRATION_STATE=prepared
else
  log "Skipping initial clone/GRUB stage; durable state is $MIGRATION_STATE"
fi

# Final sync after optionally stopping write-heavy services.
SERVICES_SPACE="${STOP_SERVICES//,/ }"
FINAL_SCRIPT=$(cat <<EOF2
set -Eeuo pipefail
echo '[guest] Starting final synchronization'
$(declare -f check_capacity estimated_capacity check_guest_capacity)
VOL_SERIAL='$NEW_SERIAL'
MNT=/mnt/root-shrink-new
STOP_SERVICES='$SERVICES_SPACE'

find_target_disk() {
  for sys in /sys/block/nvme*n1; do
    [[ -e "\$sys" ]] || continue
    serial=\$(tr -d ' ' < "\$sys/device/serial" 2>/dev/null || true)
    [[ "\$serial" == "\$VOL_SERIAL" ]] && { echo "/dev/\$(basename "\$sys")"; return 0; }
  done
  return 1
}
DST=\$(find_target_disk) || { echo "Cannot locate target disk"; exit 40; }
[[ "\$DST" == /dev/nvme* ]] && DST_PART="\${DST}p1" || DST_PART="\${DST}1"
mountpoint -q "\$MNT" || mount "\$DST_PART" "\$MNT"
[[ "\$(readlink -f "\$(findmnt -n -o SOURCE --target "\$MNT")")" == "\$DST_PART" ]] || {
  echo 'ERROR: replacement mount points to an unexpected device; aborting.' >&2
  exit 44
}
check_guest_capacity "\$MNT" filesystem '$MIN_FREE_BYTES'

if [[ -n "\$STOP_SERVICES" ]]; then
  echo "[guest] Stopping write-heavy services: \$STOP_SERVICES"
  for svc in \$STOP_SERVICES; do
    systemctl stop "\$svc"
  done
fi

RSYNC_EXCLUDES=(
  --exclude=/dev/*
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/run/*
  --exclude=/tmp/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
)
echo "[guest] Final incremental rsync starting"
rsync -aHAXx --sparse --numeric-ids --delete --info=progress2,stats2 "\${RSYNC_EXCLUDES[@]}" / "\$MNT/"
echo "[guest] Final incremental rsync complete"
TARGET_AVAIL=\$(df -B1 --output=avail "\$MNT" | awk 'NR==2 {print \$1}')
check_capacity 0 "\$TARGET_AVAIL" '$MIN_FREE_BYTES' 'free space after final copy'

# rsync may have recopied the source fstab/grub config; fix both again.
SRC_PART=\$(readlink -f "\$(findmnt -n -o SOURCE /)")
SRC_UUID=\$(blkid -s UUID -o value "\$SRC_PART")
DST_UUID=\$(blkid -s UUID -o value "\$DST_PART")
SRC_PARTUUID=\$(blkid -s PARTUUID -o value "\$SRC_PART" || true)
DST_PARTUUID=\$(blkid -s PARTUUID -o value "\$DST_PART" || true)
[[ -n "\$DST_PARTUUID" ]] || { echo "Cannot determine target PARTUUID during final sync"; exit 41; }

sed -i "s/\$SRC_UUID/\$DST_UUID/g" "\$MNT/etc/fstab" || true
if [[ -n "\$SRC_PARTUUID" ]]; then
  sed -i "s/\$SRC_PARTUUID/\$DST_PARTUUID/g" "\$MNT/etc/fstab" || true
fi

# Final rsync recopies the source GRUB defaults, including the source
# GRUB_FORCE_PARTUUID on Ubuntu AWS images. Rewrite it again before update-grub.
echo "[guest] Rewriting GRUB_FORCE_PARTUUID after final rsync"
while IFS= read -r cfg; do
  [[ -n "\$cfg" ]] || continue
  echo "[guest] Updating \$cfg"
  sed -i -E "s|^GRUB_FORCE_PARTUUID=.*$|GRUB_FORCE_PARTUUID=\$DST_PARTUUID|" "\$cfg"
done < <(
  grep -Rl '^GRUB_FORCE_PARTUUID=' \
    "\$MNT/etc/default/grub" \
    "\$MNT/etc/default/grub.d" 2>/dev/null || true
)

mount --rbind /dev "\$MNT/dev"
mount --make-rslave "\$MNT/dev"
mount -t proc proc "\$MNT/proc"
mount --rbind /sys "\$MNT/sys"
mount --make-rslave "\$MNT/sys"
mount --rbind /run "\$MNT/run"
mount --make-rslave "\$MNT/run"

cleanup_final_chroot_mounts() {
  umount -R "\$MNT/run" 2>/dev/null || true
  umount -R "\$MNT/sys" 2>/dev/null || true
  umount -R "\$MNT/proc" 2>/dev/null || true
  umount -R "\$MNT/dev" 2>/dev/null || true
}
trap cleanup_final_chroot_mounts EXIT

# Reinstall GRUB as well as regenerating grub.cfg so the final disk state is
# independently bootable after the last rsync.
chroot "\$MNT" grub-install --target=i386-pc --recheck "\$DST"
chroot "\$MNT" update-grub

echo "[guest] Validating final GRUB configuration"
grep -q "root=PARTUUID=\$DST_PARTUUID" "\$MNT/boot/grub/grub.cfg" || {
  echo "Final grub.cfg does not reference target PARTUUID \$DST_PARTUUID"
  exit 42
}
if grep -Rh '^GRUB_FORCE_PARTUUID=' \
    "\$MNT/etc/default/grub" "\$MNT/etc/default/grub.d" 2>/dev/null \
    | grep -qv "=\$DST_PARTUUID\$"; then
  echo "Stale GRUB_FORCE_PARTUUID remains after final rsync"
  exit 43
fi

cleanup_final_chroot_mounts
trap - EXIT
sync
umount "\$MNT"
echo "[guest] Running read-only ext4 consistency check"
e2fsck -fn "\$DST_PART"
echo "[guest] Final synchronization and filesystem verification complete"
echo FINAL_SYNC_OK
EOF2
)

if [[ "$MIGRATION_STATE" != "final-sync-complete" && "$MIGRATION_STATE" != "switch-started" && "$MIGRATION_STATE" != "active" ]]; then
  step "4/8: Quiesce writers and perform final incremental sync"
  log "Performing final sync${STOP_SERVICES:+ after stopping: $STOP_SERVICES}"
  FINAL_OUT="$(ssm_run "final root sync to $NEW_VOL" "$FINAL_SCRIPT" 7200)"
  printf '%s\n' "$FINAL_OUT"
  # SSM Success is authoritative. StandardOutputContent can be truncated, so do
  # not require a trailing marker to survive in stdout.
  [[ -n "$STOP_SERVICES" ]] && SERVICES_STOPPED=1
  set_state final-sync-complete
  MIGRATION_STATE=final-sync-complete
else
  log "Skipping final rsync; durable state is $MIGRATION_STATE"
fi


# Always perform a bootloader repair/validation immediately before detach/switch.
# This is intentionally independent of the durable migration state so --resume can
# safely recover replacement volumes prepared by older script versions that did not
# rewrite Ubuntu's GRUB_FORCE_PARTUUID.
if [[ "$MIGRATION_STATE" != "switch-started" && "$MIGRATION_STATE" != "active" ]]; then
  step "4.5/8: Validate and repair replacement bootloader before switch"
  BOOT_VERIFY_SCRIPT=$(cat <<EOF2
set -Eeuo pipefail
VOL_SERIAL='$NEW_SERIAL'
MNT=/mnt/root-shrink-new

find_target_disk() {
  for sys in /sys/block/nvme*n1; do
    [[ -e "\$sys" ]] || continue
    serial=\$(tr -d ' ' < "\$sys/device/serial" 2>/dev/null || true)
    [[ "\$serial" == "\$VOL_SERIAL" ]] && { echo "/dev/\$(basename "\$sys")"; return 0; }
  done
  return 1
}

DST=\$(find_target_disk) || { echo "Cannot locate target disk for boot validation"; exit 50; }
[[ "\$DST" == /dev/nvme* ]] && DST_PART="\${DST}p1" || DST_PART="\${DST}1"
mountpoint -q "\$MNT" || mount "\$DST_PART" "\$MNT"

DST_PARTUUID=\$(blkid -s PARTUUID -o value "\$DST_PART" || true)
[[ -n "\$DST_PARTUUID" ]] || { echo "Cannot determine target PARTUUID"; exit 51; }

echo "[guest] Pre-switch target disk: \$DST"
echo "[guest] Pre-switch target PARTUUID: \$DST_PARTUUID"

while IFS= read -r cfg; do
  [[ -n "\$cfg" ]] || continue
  echo "[guest] Ensuring \$cfg uses \$DST_PARTUUID"
  sed -i -E "s|^GRUB_FORCE_PARTUUID=.*$|GRUB_FORCE_PARTUUID=\$DST_PARTUUID|" "\$cfg"
done < <(
  grep -Rl '^GRUB_FORCE_PARTUUID=' \
    "\$MNT/etc/default/grub" \
    "\$MNT/etc/default/grub.d" 2>/dev/null || true
)

mount --rbind /dev "\$MNT/dev"
mount --make-rslave "\$MNT/dev"
mount -t proc proc "\$MNT/proc"
mount --rbind /sys "\$MNT/sys"
mount --make-rslave "\$MNT/sys"
mount --rbind /run "\$MNT/run"
mount --make-rslave "\$MNT/run"

cleanup_boot_verify() {
  umount -R "\$MNT/run" 2>/dev/null || true
  umount -R "\$MNT/sys" 2>/dev/null || true
  umount -R "\$MNT/proc" 2>/dev/null || true
  umount -R "\$MNT/dev" 2>/dev/null || true
}
trap cleanup_boot_verify EXIT

chroot "\$MNT" grub-install --target=i386-pc --recheck "\$DST"
chroot "\$MNT" update-grub

grep -q "root=PARTUUID=\$DST_PARTUUID" "\$MNT/boot/grub/grub.cfg" || {
  echo "ERROR: grub.cfg does not reference target PARTUUID \$DST_PARTUUID"
  exit 52
}

if grep -Rh '^GRUB_FORCE_PARTUUID=' \
    "\$MNT/etc/default/grub" "\$MNT/etc/default/grub.d" 2>/dev/null \
    | grep -qv "=\$DST_PARTUUID\$"; then
  echo "ERROR: stale GRUB_FORCE_PARTUUID remains before switch"
  exit 53
fi

cleanup_boot_verify
trap - EXIT
sync
umount "\$MNT"

echo "[guest] Pre-switch bootloader validation passed"
echo "BOOT_VALIDATION_OK PARTUUID=\$DST_PARTUUID"
EOF2
)
  BOOT_VERIFY_OUT="$(ssm_run "validate replacement root bootloader $NEW_VOL" "$BOOT_VERIFY_SCRIPT" 1800)"
  printf '%s\n' "$BOOT_VERIFY_OUT"
  set_state boot-validated
  MIGRATION_STATE=boot-validated
fi

if [[ "$MIGRATION_STATE" != "switch-started" && "$MIGRATION_STATE" != "active" ]]; then
  step "5/8: Detach prepared replacement volume"
  VOL_STATE="$(awst ec2 describe-volumes --volume-ids "$NEW_VOL" --query 'Volumes[0].State')"
  if [[ "$VOL_STATE" != "available" ]]; then
    log "Detaching prepared replacement volume $NEW_VOL"
    awsj ec2 detach-volume --volume-id "$NEW_VOL" >/dev/null
    "${AWS[@]}" ec2 wait volume-available --volume-ids "$NEW_VOL"
  else
    log "$NEW_VOL is already detached/available"
  fi
  set_state ready-to-switch
  MIGRATION_STATE=ready-to-switch
fi

step "6/8: Switch EC2 root volume"
log "Starting EC2 root-volume replacement. Original $ROOT_VOL will be retained."
SWITCH_STARTED=1
set_state switch-started
TASK_ID="$(awst ec2 create-replace-root-volume-task \
  --instance-id "$INSTANCE_ID" \
  --volume-id "$NEW_VOL" \
  --no-delete-replaced-root-volume \
  --query 'ReplaceRootVolumeTask.ReplaceRootVolumeTaskId')"
[[ "$TASK_ID" == replacevol-* ]] || die "Unexpected root replacement task ID: $TASK_ID"
log "Replacement task: $TASK_ID"

while :; do
  TASK_JSON="$(awsj ec2 describe-replace-root-volume-tasks --replace-root-volume-task-ids "$TASK_ID")"
  TASK_STATE="$(jq -r '.ReplaceRootVolumeTasks[0].TaskState' <<<"$TASK_JSON")"
  log "Replacement state: $TASK_STATE"
  case "$TASK_STATE" in
    succeeded) break ;;
    failed|failing)
      MSG="$(jq -r '.ReplaceRootVolumeTasks[0].TaskStateReason // "unknown"' <<<"$TASK_JSON")"
      die "Root replacement failed: $MSG"
      ;;
    *) sleep 10 ;;
  esac
done

step "7/8: Wait for reboot and EC2 health checks"
log "Waiting for EC2 instance status checks"
"${AWS[@]}" ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

# Existing-volume replacement does not inherit the old DeleteOnTermination setting.
log "Restoring root DeleteOnTermination=$DELETE_ON_TERMINATION"
"${AWS[@]}" ec2 modify-instance-attribute \
  --instance-id "$INSTANCE_ID" \
  --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEV\",\"Ebs\":{\"DeleteOnTermination\":$DELETE_ON_TERMINATION}}]"

# Tag both volumes so rollback/cleanup is obvious.
"${AWS[@]}" ec2 create-tags --resources "$NEW_VOL" --tags \
  Key=RootShrinkState,Value=active \
  Key=RootShrinkPreviousVolume,Value="$ROOT_VOL" >/dev/null
MIGRATION_STATE=active
"${AWS[@]}" ec2 create-tags --resources "$ROOT_VOL" --tags \
  Key=RootShrinkState,Value=rollback \
  Key=RootShrinkReplacementVolume,Value="$NEW_VOL" >/dev/null

# Verify from the guest after SSM reconnects.
step "8/8: Verify new root from inside the guest"
log "Waiting for SSM to return Online after reboot"
for _ in {1..60}; do
  PING="$(awst ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[0].PingStatus' 2>/dev/null || true)"
  [[ "$PING" == "Online" ]] && break
  sleep 5
done
[[ "$PING" == "Online" ]] || warn "EC2 checks passed, but SSM did not return Online within the verification window"

if [[ "$PING" == "Online" ]]; then
  VERIFY_SCRIPT='set -e; echo "=== root ==="; findmnt /; echo "=== df ==="; df -hT /; echo "=== disks ==="; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS; echo "=== failed units ==="; systemctl --failed --no-pager || true'
  VERIFY_OUT="$(ssm_run "verify replacement root" "$VERIFY_SCRIPT" 300)"
  printf '\n%s\n' "$VERIFY_OUT"
fi

trap - ERR
cat <<DONE

SUCCESS
-------
Instance:            $INSTANCE_ID
Old root volume:     $ROOT_VOL   (retained for rollback)
New root volume:     $NEW_VOL   (${TARGET_SIZE} GiB gp3)
Replacement task:    $TASK_ID
DeleteOnTermination: $DELETE_ON_TERMINATION

Do NOT delete the old root immediately. Verify the application first, then remove
$ROOT_VOL manually after your chosen rollback period.
DONE
