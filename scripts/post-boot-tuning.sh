#!/usr/bin/env bash
#
# 02-post-boot-tuning.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# Stage 2 of 2. Run AFTER stage 1 and AFTER the reboot into kernel 7.0.0-28.
#
# Clones the project repo and runs its own post-boot-setup.sh (phases A-D, F, G),
# then applies the supplementary checks that script does not cover.
#
# Phase E (firmware -> Secure Boot -> TPM) is deliberately NOT run here: it
# requires BIOS visits and reboots in a fixed order. See the tail of this script.
#
set -uo pipefail

REPO_URL="https://github.com/MensuraMedia/dell-lattitude-7420-optimization"
WORKDIR="/opt/dell-7420-optimization"
STAMP="$(date +%Y%m%d-%H%M%S)"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
hdr()  { echo; bold "════ $* ════"; }
die()  { red "ABORT: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sudo)"

bold "Latitude 7420 — Stage 2: post-boot tuning"
echo "  kernel: $(uname -r)"

# ── Preconditions ────────────────────────────────────────────────────────────
hdr "Preconditions"

TS_UUID="$(python3 -c "import json;print(json.load(open('/etc/timeshift/timeshift.json')).get('backup_device_uuid',''))" 2>/dev/null)"
BOOT_UUID="$(findmnt -no UUID /boot)"
if [[ "$TS_UUID" == "$BOOT_UUID" ]]; then
  die "Timeshift is STILL targeting /boot. Run stage 1 first."
fi
grn "  Timeshift is not targeting /boot"

PENDING="$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
echo "  pending updates: $PENDING"
[[ "$PENDING" -gt 20 ]] && ylw "  stage 1 upgrade may not have completed"

echo "  /boot: $(findmnt -no USED,AVAIL,USE% /boot)"

# ── Microcode / GDS verdict ──────────────────────────────────────────────────
hdr "Microcode and GDS"
echo "  running revision : $(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')"
echo "  intel-microcode  : $(dpkg-query -W -f='${Version}' intel-microcode 2>/dev/null)"
GDS="$(cat /sys/devices/system/cpu/vulnerabilities/gather_data_sampling)"
if [[ "$GDS" == *Vulnerable* ]]; then
  red   "  GDS: $GDS"
  echo  "  The Ubuntu microcode package cannot raise this CPU past what Dell's"
  echo  "  BIOS already loads. Remaining option is a BIOS update:"
  echo  "      sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates"
  echo  "  If no BIOS update mitigates it, doc 11's acceptance criterion"
  echo  "  'GDS not Vulnerable' is unreachable and should be amended."
else
  grn   "  GDS: $GDS"
fi

# ── Fetch and run the project's own script ───────────────────────────────────
hdr "Project repository"
if [[ -d "$WORKDIR/.git" ]]; then
  git -C "$WORKDIR" pull --ff-only >/dev/null 2>&1 && grn "  updated $WORKDIR" || ylw "  pull failed, using existing checkout"
else
  if git clone --depth 1 "$REPO_URL" "$WORKDIR" >/dev/null 2>&1; then
    grn "  cloned to $WORKDIR"
  else
    die "clone failed — check network"
  fi
fi

SETUP="$WORKDIR/scripts/post-boot-setup.sh"
[[ -f "$SETUP" ]] || die "post-boot-setup.sh not found in the repo"
chmod +x "$SETUP"

hdr "Dry run (review before applying)"
bash "$SETUP" --dry-run

echo
read -rp "  Apply these changes? [y/N] " ANS
[[ "${ANS,,}" == "y" ]] || { ylw "  aborted by user — nothing changed"; exit 0; }

hdr "Applying phases A-D, F, G"
bash "$SETUP"

# ── Supplementary: things post-boot-setup.sh does not check ──────────────────
hdr "Supplementary verification"

echo "  --- mount options (expect noatime on / /home /boot) ---"
findmnt -no TARGET,OPTIONS / /home /boot | sed 's/^/    /'

echo "  --- swap topology (zram must be priority 100, above lv_swap) ---"
swapon --show | sed 's/^/    /'
if swapon --show=NAME --noheadings | grep -q zram; then
  grn "  zram active"
else
  ylw "  zram NOT active — check: systemctl status zramswap"
fi

echo "  --- vm tunables ---"
sysctl vm.swappiness vm.vfs_cache_pressure | sed 's/^/    /'

echo "  --- power daemons (exactly one should be active) ---"
printf '    %-26s %s\n' "tlp" "$(systemctl is-active tlp 2>/dev/null)"
printf '    %-26s %s\n' "power-profiles-daemon" "$(systemctl is-active power-profiles-daemon 2>/dev/null)"
printf '    %-26s %s\n' "thermald" "$(systemctl is-active thermald 2>/dev/null)"
if systemctl is-active tlp &>/dev/null && systemctl is-active power-profiles-daemon &>/dev/null; then
  red "  BOTH TLP and power-profiles-daemon are active — they fight over the same sysfs knobs"
fi

echo "  --- battery ---"
printf '    %-26s %s\n' "charge start/stop" \
  "$(cat /sys/class/power_supply/BAT0/charge_control_start_threshold 2>/dev/null)/$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null)"
if [[ -r /sys/class/power_supply/BAT0/energy_full_design ]]; then
  D=$(cat /sys/class/power_supply/BAT0/energy_full_design)
  F=$(cat /sys/class/power_supply/BAT0/energy_full)
  printf '    %-26s %s%%\n' "health vs design" "$(( F * 100 / D ))"
fi

echo "  --- SSD health ---"
smartctl -a /dev/nvme0n1 2>/dev/null \
  | grep -E 'Percentage Used|Available Spare:|Media and Data|Unsafe Shutdowns' | sed 's/^/    /'

echo "  --- storage allocation ---"
vgs --units g 2>/dev/null | sed 's/^/    /'
lvs --units g 2>/dev/null | sed 's/^/    /'
df -hT -x tmpfs -x devtmpfs -x efivarfs | sed 's/^/    /'

echo "  --- failed units ---"
systemctl --failed --no-legend | sed 's/^/    /' || echo "    none"

echo "  --- obsolete packages (simulation only, nothing removed) ---"
apt-get -s autoremove --purge 2>/dev/null | grep -E '^Remv' | sed 's/^/    /' || echo "    none"
ylw "  review the list above, then run 'sudo apt autoremove --purge' if it looks right"

# ── What is left ─────────────────────────────────────────────────────────────
hdr "REMAINING — Phase E, in this exact order"
cat <<'EOF'
  Order matters: a BIOS update changes PCR 0 and Secure Boot changes PCR 7.
  Enrolling the TPM before either one silently invalidates the binding.

    11. Firmware       sudo fwupdmgr refresh --force
                       sudo fwupdmgr get-updates
                       sudo fwupdmgr update          (AC power required)
                       reboot

    12. Secure Boot    sudo apt install --reinstall shim-signed grub-efi-amd64-signed
                       sudo update-grub
                       reboot -> F2 -> Secure Boot: Enabled, Deployed Mode
                       verify: mokutil --sb-state

    13. TPM unlock     sudo /opt/dell-7420-optimization/scripts/post-boot-setup.sh --tpm
                       reboot — should reach the desktop with no passphrase
                       verify: sudo systemd-cryptenroll /dev/nvme0n1p3

  Hardware — no software step substitutes:
    F-01  Battery at ~24% of design health (14.6 Wh of 61.9 Wh). Replace it.
    F-09  Adapter negotiating 45 W on a 65 W platform. Check the label.

  Still manual:
    Copy /root/luks-backup/luks-header-nvme0n1p3.img to external media.
    Consider a second LUKS keyslot: sudo cryptsetup luksAddKey /dev/nvme0n1p3
EOF
echo
