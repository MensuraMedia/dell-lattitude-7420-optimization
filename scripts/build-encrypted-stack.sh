#!/usr/bin/env bash
#
# build-encrypted-stack.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# Creates the LUKS2 container, the LVM stack and all filesystems on an
# already-partitioned disk, per docs/08-reference-architecture.md.
#
#   p3 → LUKS2 → LVM vg_mint → lv_root (120G, ext4)  → /
#                             → lv_home (280G, ext4)  → /home
#                             → lv_swap  (20G, swap)
#                             → ~53 GiB unallocated reserve
#
# ⚠️  DESTRUCTIVE. Overwrites /dev/nvme0n1p3 completely.
#
# You will be prompted TWICE by cryptsetup:
#   1. type YES in capitals to confirm the wipe
#   2. set the passphrase (entered twice), then enter it once more to open
#
# Usage:
#   sudo ./scripts/build-encrypted-stack.sh
#   sudo ./scripts/build-encrypted-stack.sh --device /dev/nvme0n1p3
#   sudo ./scripts/build-encrypted-stack.sh --no-encrypt     # plain LVM, no LUKS
#
set -euo pipefail

DEV="/dev/nvme0n1p3"
MAPPER_NAME="cryptsystem"
VG="vg_mint"
ROOT_SIZE="120G"
HOME_SIZE="280G"
SWAP_SIZE="20G"
ENCRYPT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)     DEV="$2"; shift 2 ;;
    --no-encrypt) ENCRYPT=0; shift ;;
    -h|--help)    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()   { red "ABORT: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"

# ── Pre-flight ─────────────────────────────────────────────────────────────
bold "=== PRE-FLIGHT CHECKS ==="

[[ -b "$DEV" ]] || die "$DEV is not a block device"

# Never operate on the disk we booted from.
LIVE_SRC="$(findmnt -n -o SOURCE /cdrom 2>/dev/null || true)"
if [[ -n "$LIVE_SRC" ]]; then
  LIVE_DISK="/dev/$(lsblk -no pkname "$LIVE_SRC" 2>/dev/null || true)"
  TARGET_DISK="/dev/$(lsblk -no pkname "$DEV")"
  [[ "$LIVE_DISK" == "$TARGET_DISK" ]] && die "$DEV is on the live USB ($LIVE_DISK)!"
  echo "  live medium : $LIVE_SRC (on $LIVE_DISK) — not the target ✓"
fi

echo "  target      : $DEV ($(lsblk -no SIZE "$DEV" | xargs))"

mount | grep -q "^${DEV} " && die "$DEV is mounted — unmount it first"
echo "  mounted     : no ✓"

AC="$(cat /sys/class/power_supply/A[CD]*/online 2>/dev/null | head -1 || echo 0)"
if [[ "$AC" != "1" ]]; then
  red "  AC power    : NOT CONNECTED"
  red ""
  red "  This machine's battery is at ~23.6% of design health and has caused"
  red "  26 unsafe shutdowns. Connect AC before writing to the disk."
  die "connect AC power and re-run"
fi
echo "  AC power    : connected ✓"

if vgs "$VG" &>/dev/null; then
  die "volume group '$VG' already exists — remove it first (vgremove $VG)"
fi
echo "  vg '$VG'  : does not exist ✓"

echo
bold "=== WILL CREATE ==="
if [[ $ENCRYPT -eq 1 ]]; then
  echo "  $DEV → LUKS2 (aes-xts-plain64, 512-bit key, argon2id)"
  echo "    └─ /dev/mapper/$MAPPER_NAME → LVM PV"
else
  red   "  $DEV → LVM PV  (NO ENCRYPTION)"
fi
cat <<EOF
       └─ VG $VG
            ├─ lv_root  $ROOT_SIZE  ext4  → /
            ├─ lv_home  $HOME_SIZE  ext4  → /home
            ├─ lv_swap   $SWAP_SIZE  swap
            └─ remainder unallocated (SSD over-provisioning reserve)
EOF
echo
red "⚠️  ALL DATA ON $DEV WILL BE DESTROYED."
echo
read -rp "Type 'proceed' to continue: " CONFIRM
[[ "$CONFIRM" == "proceed" ]] || die "not confirmed"
echo

# ── LUKS2 ──────────────────────────────────────────────────────────────────
if [[ $ENCRYPT -eq 1 ]]; then
  bold "=== [1/4] CREATING LUKS2 CONTAINER ==="
  echo "cryptsetup will ask you to type YES (capitals), then set a passphrase."
  echo
  cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha256 \
    --pbkdf argon2id \
    --label cryptsystem \
    "$DEV"

  echo
  echo "Now enter that same passphrase once more to open the container:"
  cryptsetup open "$DEV" "$MAPPER_NAME"
  PV_DEV="/dev/mapper/$MAPPER_NAME"
  green "  LUKS2 container created and opened ✓"
else
  PV_DEV="$DEV"
  wipefs -a "$DEV"
fi
echo

# ── LVM ────────────────────────────────────────────────────────────────────
bold "=== [2/4] BUILDING LVM STACK ==="
pvcreate -ff -y "$PV_DEV"
vgcreate "$VG" "$PV_DEV"
lvcreate -y -L "$ROOT_SIZE" -n lv_root "$VG"
lvcreate -y -L "$HOME_SIZE" -n lv_home "$VG"
lvcreate -y -L "$SWAP_SIZE" -n lv_swap "$VG"
green "  volume group '$VG' created ✓"
echo

# ── Filesystems ────────────────────────────────────────────────────────────
bold "=== [3/4] CREATING FILESYSTEMS ==="
mkfs.ext4 -F -L mint-root "/dev/$VG/lv_root"
mkfs.ext4 -F -L mint-home "/dev/$VG/lv_home"
mkswap       -L mint-swap "/dev/$VG/lv_swap"
green "  filesystems created ✓"
echo

# ── Verify ─────────────────────────────────────────────────────────────────
bold "=== [4/4] VERIFICATION ==="
echo
echo "--- block topology ---"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$(lsblk -no pkname "$DEV" | sed 's|^|/dev/|')"
echo
echo "--- volume group (Free PE must be > 0) ---"
vgdisplay "$VG" | grep -E 'VG Size|Alloc PE|Free  PE'
echo
echo "--- logical volumes ---"
lvs -o lv_name,lv_size,lv_path "$VG"
if [[ $ENCRYPT -eq 1 ]]; then
  echo
  echo "--- LUKS header ---"
  cryptsetup luksDump "$DEV" | grep -E 'Version|Label|Cipher|PBKDF|Memory|Threads' | head -12
fi
echo
echo "--- TRIM path to device ---"
lsblk --discard "$(lsblk -no pkname "$DEV" | sed 's|^|/dev/|')"

echo
green "════════════════════════════════════════════════════════════════"
green " STACK BUILT SUCCESSFULLY"
green "════════════════════════════════════════════════════════════════"
cat <<EOF

Next: run the Mint installer, choose "Something else", and use Table 1 in
docs/09-installer-reference-table.md:

  /dev/nvme0n1p1              EFI System Partition   (auto)    format ✓   1074 MB
  /dev/nvme0n1p2              Ext4                   /boot     format ✓   2147 MB
  /dev/mapper/${VG}-lv_root   Ext4                   /         format ✓ 128849 MB
  /dev/mapper/${VG}-lv_home   Ext4                   /home     format ✓ 300648 MB
  /dev/mapper/${VG}-lv_swap   swap area              —                    21475 MB

  Bootloader device: /dev/nvme0n1     <-- the DISK, not a partition

⚠️  DO NOT REBOOT when the installer finishes — choose "Continue Testing".
    You must first repair /etc/crypttab, or the machine will not boot.
    See docs/08-reference-architecture.md Step 8, or run:

      sudo ./scripts/post-install-crypttab.sh

EOF
