#!/usr/bin/env bash
#
# post-install-crypttab.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# Repairs the encryption configuration of a freshly installed Mint system that
# was installed onto a MANUALLY created LUKS+LVM stack.
#
# The Mint installer does not reliably write /etc/crypttab in that case, and it
# may omit cryptsetup/lvm2 from the initramfs. Without this the machine boots to
# an initramfs prompt and never finds the root filesystem.
#
# Run from the LIVE USB, after the installer finishes and BEFORE rebooting.
#
# Usage:
#   sudo ./scripts/post-install-crypttab.sh
#   sudo ./scripts/post-install-crypttab.sh --luks-part /dev/nvme0n1p3 \
#        --boot-part /dev/nvme0n1p2 --esp /dev/nvme0n1p1 --vg vg_mint
#
set -euo pipefail

LUKS_PART="/dev/nvme0n1p3"
BOOT_PART="/dev/nvme0n1p2"
ESP_PART="/dev/nvme0n1p1"
MAPPER_NAME="cryptsystem"
VG="vg_mint"
TARGET="/mnt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --luks-part) LUKS_PART="$2"; shift 2 ;;
    --boot-part) BOOT_PART="$2"; shift 2 ;;
    --esp)       ESP_PART="$2";  shift 2 ;;
    --vg)        VG="$2";        shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()   { red "ABORT: $*"; exit 1; }

cleanup() {
  set +e
  for d in run sys proc dev/pts dev; do umount "$TARGET/$d" 2>/dev/null; done
  umount "$TARGET/boot/efi" 2>/dev/null
  umount "$TARGET/boot" 2>/dev/null
  umount "$TARGET" 2>/dev/null
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"

bold "=== OPENING THE INSTALLED SYSTEM ==="

if [[ ! -e "/dev/mapper/$MAPPER_NAME" ]]; then
  echo "Enter the LUKS passphrase to unlock $LUKS_PART:"
  cryptsetup open "$LUKS_PART" "$MAPPER_NAME"
fi
green "  LUKS container open ✓"

vgchange -ay "$VG" >/dev/null
green "  volume group '$VG' active ✓"

[[ -e "/dev/$VG/lv_root" ]] || die "/dev/$VG/lv_root not found"

mount "/dev/$VG/lv_root" "$TARGET"
mount "$BOOT_PART" "$TARGET/boot"
mkdir -p "$TARGET/boot/efi"
mount "$ESP_PART" "$TARGET/boot/efi"
for d in dev dev/pts proc sys run; do mount --bind "/$d" "$TARGET/$d"; done
cp /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true
green "  installed system mounted at $TARGET ✓"
echo

LUKS_UUID="$(blkid -s UUID -o value "$LUKS_PART")"
[[ -n "$LUKS_UUID" ]] || die "could not read LUKS UUID from $LUKS_PART"
echo "  LUKS UUID: $LUKS_UUID"
echo

bold "=== REPAIRING INSIDE THE CHROOT ==="
chroot "$TARGET" /bin/bash -s -- "$MAPPER_NAME" "$LUKS_UUID" <<'CHROOT'
set -euo pipefail
MAPPER_NAME="$1"
LUKS_UUID="$2"

echo "--- /etc/crypttab ---"
touch /etc/crypttab
if grep -q "$LUKS_UUID" /etc/crypttab 2>/dev/null; then
  echo "  entry already present, leaving as-is"
else
  # 'discard' enables TRIM pass-through to the SSD through the LUKS layer.
  # Without it, fstrim silently does nothing on this DRAM-less drive.
  echo "${MAPPER_NAME} UUID=${LUKS_UUID} none luks,discard" >> /etc/crypttab
  echo "  entry added"
fi
cat /etc/crypttab
echo

echo "--- ensuring initramfs tooling is installed ---"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq cryptsetup-initramfs lvm2 2>&1 | tail -3

echo
echo "--- rebuilding initramfs ---"
update-initramfs -u -k all

echo
echo "--- updating GRUB ---"
update-grub
CHROOT

echo
bold "=== VERIFICATION ==="
FAIL=0

echo -n "  /etc/crypttab has the LUKS UUID ... "
if grep -q "$LUKS_UUID" "$TARGET/etc/crypttab"; then green "PASS"; else red "FAIL"; FAIL=1; fi

echo -n "  cryptsetup present in initramfs  ... "
KVER="$(ls "$TARGET"/boot/initrd.img-* 2>/dev/null | head -1)"
if [[ -n "$KVER" ]] && lsinitramfs "$KVER" 2>/dev/null | grep -q cryptsetup; then
  green "PASS"
else red "FAIL"; FAIL=1; fi

echo -n "  lvm present in initramfs         ... "
if [[ -n "$KVER" ]] && lsinitramfs "$KVER" 2>/dev/null | grep -q 'sbin/lvm'; then
  green "PASS"
else red "FAIL"; FAIL=1; fi

echo -n "  /boot entry in fstab             ... "
if grep -qE '\s/boot\s' "$TARGET/etc/fstab"; then green "PASS"; else red "FAIL"; FAIL=1; fi

echo -n "  /boot/efi entry in fstab         ... "
if grep -qE '\s/boot/efi\s' "$TARGET/etc/fstab"; then green "PASS"; else red "FAIL"; FAIL=1; fi

echo -n "  GRUB EFI binary installed        ... "
if [[ -f "$TARGET/boot/efi/EFI/ubuntu/grubx64.efi" ]]; then green "PASS"; else red "FAIL"; FAIL=1; fi

echo
echo "--- /etc/fstab ---"
grep -vE '^\s*#' "$TARGET/etc/fstab" | grep -v '^\s*$'

echo
if [[ $FAIL -eq 0 ]]; then
  green "════════════════════════════════════════════════════════════════"
  green " ALL CHECKS PASSED — safe to reboot"
  green "════════════════════════════════════════════════════════════════"
  cat <<'EOF'

Reboot now. You should be prompted for the LUKS passphrase, then reach the
Mint desktop.

After the first successful boot, apply in order:

  1. sudo apt install intel-microcode        # F-06: GDS/Downfall — do this first
  2. sudo systemctl enable --now fstrim.timer
  3. TPM auto-unlock (optional, no more passphrase at boot):
       sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p3
       sudo update-initramfs -u -k all
  4. Enable Secure Boot           → docs/06-bios-uefi-configuration.md
  5. Full tuning pass             → docs/05-post-install-optimization.md
  6. Validate                     → docs/08-reference-architecture.md Part 6

STILL OUTSTANDING (hardware — no software fix):
  F-01  Battery at 23.65% of design health — replace it
  F-09  AC adapter negotiating 45 W on a 65 W platform — verify/replace

EOF
else
  red "════════════════════════════════════════════════════════════════"
  red " SOME CHECKS FAILED — do NOT reboot yet"
  red "════════════════════════════════════════════════════════════════"
  echo
  echo "See the recovery table in docs/09-installer-reference-table.md"
  exit 1
fi
