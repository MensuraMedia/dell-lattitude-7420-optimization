#!/usr/bin/env bash
#
# post-boot-setup.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# Runs the post-boot optimization phases from docs/11-post-boot-runbook.md in
# dependency order. Run ON THE INSTALLED SYSTEM after the first successful boot,
# NOT from the live USB.
#
# Idempotent: safe to re-run. Each step detects existing state and skips.
#
# Phases:
#   A  security + data safety   (microcode, LUKS header backup, boot-chain proof)
#   B  storage + memory         (TRIM, noatime, sysctl, zram)
#   C  power + thermal          (thermald, TLP, charge thresholds)
#   D  graphics + media         (VA-API)
#   E  boot security            (firmware, Secure Boot prep, TPM)  <- order matters
#   F  resilience               (hibernation, Timeshift, journald)
#   G  validation
#
# Usage:
#   sudo ./scripts/post-boot-setup.sh                # phases A-D, F, G
#   sudo ./scripts/post-boot-setup.sh --all          # also E (firmware/SecureBoot prep)
#   sudo ./scripts/post-boot-setup.sh --phase B      # one phase only
#   sudo ./scripts/post-boot-setup.sh --dry-run      # show, change nothing
#   sudo ./scripts/post-boot-setup.sh --new-battery  # charge thresholds 75/80
#   sudo ./scripts/post-boot-setup.sh --tpm          # enrol TPM (needs passphrase)
#
set -uo pipefail

LUKS_PART="/dev/nvme0n1p3"
VG="vg_mint"
DRY=0
NEW_BATTERY=0
DO_TPM=0
DO_ALL=0
ONLY_PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY=1; shift ;;
    --new-battery) NEW_BATTERY=1; shift ;;
    --tpm)         DO_TPM=1; shift ;;
    --all)         DO_ALL=1; shift ;;
    --phase)       ONLY_PHASE="${2^^}"; shift 2 ;;
    --luks-part)   LUKS_PART="$2"; shift 2 ;;
    -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
hdr()    { echo; bold "════ $* ════"; }
step()   { printf '  %-46s ' "$*"; }
ok()     { green "OK"; }
skip()   { yellow "already done"; }
warn()   { yellow "$*"; }
die()    { red "ABORT: $*"; exit 1; }

run() {
  if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] $*"; return 0; fi
  "$@" >/dev/null 2>&1
}

want_phase() { [[ -z "$ONLY_PHASE" || "$ONLY_PHASE" == "$1" ]]; }

# ── Guards ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"

if findmnt -n /cdrom &>/dev/null || [[ -d /rofs ]]; then
  die "this looks like the LIVE USB. Run post-boot-setup.sh on the INSTALLED system, after rebooting."
fi

[[ -b "$LUKS_PART" ]] || warn "LUKS partition $LUKS_PART not found — some steps will be skipped"

REBOOT_NEEDED=0
NOTES=()

bold "Dell Latitude 7420 — post-boot setup"
echo "  mode: $([[ $DRY -eq 1 ]] && echo 'DRY RUN (no changes)' || echo 'APPLY')"
echo "  see docs/11-post-boot-runbook.md for the rationale behind each step"

# ═══ PHASE A ═══════════════════════════════════════════════════════════════
if want_phase A; then
hdr "PHASE A — security and data safety"

step "1. intel-microcode (F-06 Downfall)"
if dpkg -s intel-microcode &>/dev/null; then skip; else
  run apt-get update -qq
  if run apt-get install -y -qq intel-microcode; then ok; REBOOT_NEEDED=1
  else red "FAILED"; NOTES+=("intel-microcode install failed — check network/apt"); fi
fi

step "   GDS mitigation status"
GDS=$(cat /sys/devices/system/cpu/vulnerabilities/gather_data_sampling 2>/dev/null || echo unknown)
if [[ "$GDS" == *Vulnerable* ]]; then
  yellow "$GDS"
  NOTES+=("GDS still reports Vulnerable — reboot required for microcode to load")
else green "$GDS"; fi

step "2. LUKS header backup"
HDR_DIR="/root/luks-backup"
HDR_FILE="$HDR_DIR/luks-header-$(basename "$LUKS_PART").img"
if [[ -s "$HDR_FILE" ]]; then skip; else
  if [[ -b "$LUKS_PART" ]]; then
    run mkdir -p "$HDR_DIR"
    if run cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$HDR_FILE"; then
      run chmod 600 "$HDR_FILE"; ok
    else red "FAILED"; fi
  else yellow "no LUKS partition"; fi
fi
[[ -s "$HDR_FILE" ]] && NOTES+=("COPY $HDR_FILE TO EXTERNAL MEDIA — it is key material, never commit it to git")

step "   LUKS keyslot count"
if [[ -b "$LUKS_PART" ]]; then
  KS=$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null | grep -cE '^  [0-9]+: luks2' || true)
  if [[ "${KS:-0}" -lt 2 ]]; then
    yellow "$KS — single point of failure"
    NOTES+=("Only $KS LUKS keyslot. Add a recovery passphrase: sudo cryptsetup luksAddKey $LUKS_PART")
  else green "$KS"; fi
else yellow "n/a"; fi

step "3. boot chain sanity"
if [[ -f /etc/crypttab ]] && grep -q luks /etc/crypttab 2>/dev/null; then
  grep -q discard /etc/crypttab && ok || { yellow "no 'discard'"; NOTES+=("/etc/crypttab lacks 'discard' — TRIM will not reach the SSD"); }
else yellow "no crypttab entry"; fi
fi

# ═══ PHASE B ═══════════════════════════════════════════════════════════════
if want_phase B; then
hdr "PHASE B — storage and memory"

step "4. fstrim.timer"
if systemctl is-enabled fstrim.timer &>/dev/null; then skip; else
  run systemctl enable --now fstrim.timer && ok || red "FAILED"
fi

step "   run fstrim now"
if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] fstrim -av"; else
  if fstrim -av >/dev/null 2>&1; then ok; else yellow "returned an error"; NOTES+=("fstrim failed — check 'discard' in /etc/crypttab"); fi
fi

step "5. noatime in fstab"
if grep -qE '^[^#].*\s/\s+ext4.*noatime' /etc/fstab; then skip; else
  if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] add noatime to / /home /boot"; else
    cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    # add noatime to ext4 lines for / /home /boot that lack it
    awk '{
      if ($0 !~ /^#/ && $3 == "ext4" && ($2=="/" || $2=="/home" || $2=="/boot") && $4 !~ /noatime/) {
        $4 = $4 ",noatime"
      }
      print
    }' OFS='\t' /etc/fstab > /tmp/fstab.new && mv /tmp/fstab.new /etc/fstab
    if findmnt -n / >/dev/null; then ok; else red "CHECK /etc/fstab"; fi
  fi
  NOTES+=("fstab modified (backup at /etc/fstab.bak.*) — verify with: findmnt -o TARGET,OPTIONS / /home")
fi

step "6. sysctl vm tuning"
if [[ -f /etc/sysctl.d/99-mint-tuning.conf ]]; then skip; else
  if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] write /etc/sysctl.d/99-mint-tuning.conf"; else
    cat > /etc/sysctl.d/99-mint-tuning.conf <<'EOF'
# Dell Latitude 7420: 16 GB RAM (soldered), DRAM-less NVMe.
# Swap late; keep dentry/inode cache longer to avoid metadata re-reads.
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl --system >/dev/null 2>&1 && ok || red "FAILED"
  fi
fi

step "7. zram (zstd, 25%, priority 100)"
if dpkg -s zram-tools &>/dev/null && grep -q 'PRIORITY=100' /etc/default/zramswap 2>/dev/null; then skip; else
  if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] install zram-tools + configure"; else
    apt-get install -y -qq zram-tools >/dev/null 2>&1
    cat > /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=25
PRIORITY=100
EOF
    systemctl restart zramswap >/dev/null 2>&1 && ok || red "FAILED"
  fi
fi
fi

# ═══ PHASE C ═══════════════════════════════════════════════════════════════
if want_phase C; then
hdr "PHASE C — power and thermal"

step "8. thermald"
if systemctl is-active thermald &>/dev/null; then skip; else
  run apt-get install -y -qq thermald
  run systemctl enable --now thermald && ok || red "FAILED"
fi

step "9. TLP"
if dpkg -s tlp &>/dev/null; then skip; else
  run apt-get install -y -qq tlp tlp-rdw
  run systemctl enable --now tlp && ok || red "FAILED"
fi

step "   power-profiles-daemon conflict"
if systemctl is-active power-profiles-daemon &>/dev/null; then
  yellow "ACTIVE — conflicts with TLP"
  run systemctl mask --now power-profiles-daemon
  NOTES+=("power-profiles-daemon was active and has been masked (it fights TLP over the same sysfs knobs)")
else green "clear"; fi

# Charge thresholds. On the ORIGINAL battery (23.6% health) capping at 80%
# leaves under an hour of runtime, so default to 100 unless --new-battery.
if [[ $NEW_BATTERY -eq 1 ]]; then START=75; STOP=80; else START=95; STOP=100; fi
step "   TLP config (charge stop ${STOP}%)"
if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] write /etc/tlp.d/01-latitude-7420.conf"; else
  cat > /etc/tlp.d/01-latitude-7420.conf <<EOF
# Dell Latitude 7420 (Tiger Lake i5-1145G7) — see docs/05 and docs/11
CPU_DRIVER_OPMODE_ON_AC=active
CPU_DRIVER_OPMODE_ON_BAT=active
# With intel_pstate active + HWP, 'powersave' is the full-range governor.
# Frequency behaviour is steered by ENERGY_PERF_POLICY (the EPP hint) below.
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# Enables the NVMe deep power states (0.05 W / 0.005 W)
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

INTEL_GPU_MIN_FREQ_ON_AC=100
INTEL_GPU_MIN_FREQ_ON_BAT=100

WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

USB_AUTOSUSPEND=1
USB_EXCLUDE_BTUSB=1

START_CHARGE_THRESH_BAT0=${START}
STOP_CHARGE_THRESH_BAT0=${STOP}
EOF
  systemctl restart tlp >/dev/null 2>&1 && ok || red "FAILED"
fi
[[ $NEW_BATTERY -eq 0 ]] && NOTES+=("Charge threshold left at ${STOP}% — the current battery is at ~23.6% health, so capping it would leave under an hour. Re-run with --new-battery after replacing it.")

step "   battery health"
if [[ -r /sys/class/power_supply/BAT0/energy_full_design ]]; then
  D=$(cat /sys/class/power_supply/BAT0/energy_full_design)
  F=$(cat /sys/class/power_supply/BAT0/energy_full)
  PCT=$(( F * 100 / D ))
  if [[ $PCT -lt 50 ]]; then red "${PCT}% of design — REPLACE (F-01)"; NOTES+=("Battery at ${PCT}% of design health — hardware replacement required (F-01)")
  else green "${PCT}% of design"; fi
else yellow "n/a"; fi
fi

# ═══ PHASE D ═══════════════════════════════════════════════════════════════
if want_phase D; then
hdr "PHASE D — graphics and media"

step "10. VA-API (intel-media-va-driver-non-free)"
if dpkg -s intel-media-va-driver-non-free &>/dev/null; then skip; else
  run apt-get install -y -qq intel-media-va-driver-non-free vainfo && ok || red "FAILED"
fi

step "    codec profiles available"
if command -v vainfo &>/dev/null && [[ $DRY -eq 0 ]]; then
  N=$(vainfo 2>/dev/null | grep -cE 'VAProfile(H264|HEVC|VP9|AV1)' || true)
  [[ "${N:-0}" -gt 0 ]] && green "$N profiles" || { yellow "none detected"; NOTES+=("VA-API reports no profiles — check 'vainfo' output"); }
else yellow "skipped"; fi
fi

# ═══ PHASE E ═══════════════════════════════════════════════════════════════
if want_phase E && { [[ $DO_ALL -eq 1 ]] || [[ "$ONLY_PHASE" == "E" ]] || [[ $DO_TPM -eq 1 ]]; }; then
hdr "PHASE E — boot security  (order: firmware → Secure Boot → TPM)"

step "11. firmware updates available"
if command -v fwupdmgr &>/dev/null && [[ $DRY -eq 0 ]]; then
  fwupdmgr refresh --force >/dev/null 2>&1 || true
  if fwupdmgr get-updates >/dev/null 2>&1; then
    yellow "updates available"
    NOTES+=("Firmware updates are available. Run 'sudo fwupdmgr update' on AC power BEFORE enrolling the TPM — a BIOS update changes PCR 0 and invalidates the binding.")
  else green "none pending"; fi
else yellow "skipped"; fi

step "12. Secure Boot signed bootloader"
if dpkg -s shim-signed &>/dev/null && dpkg -s grub-efi-amd64-signed &>/dev/null; then skip; else
  run apt-get install -y -qq shim-signed grub-efi-amd64-signed
  run update-grub && ok || red "FAILED"
fi

step "    Secure Boot state"
SB=$(mokutil --sb-state 2>/dev/null | head -1 || echo unknown)
if [[ "$SB" == *disabled* ]]; then
  yellow "$SB"
  NOTES+=("Secure Boot is disabled. Enable it in BIOS (F2 → Secure Boot → Enabled, Deployed Mode). Do this BEFORE TPM enrolment — PCR 7 measures Secure Boot state.")
else green "$SB"; fi

if [[ $DO_TPM -eq 1 ]]; then
  step "13. TPM auto-unlock enrolment"
  if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7"; else
    echo
    yellow "    You will be prompted for your LUKS passphrase."
    if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$LUKS_PART"; then
      update-initramfs -u -k all >/dev/null 2>&1
      green "    TPM enrolled"; REBOOT_NEEDED=1
    else red "    enrolment failed"; fi
  fi
else
  step "13. TPM enrolment"; yellow "skipped (pass --tpm)"
fi
fi

# ═══ PHASE F ═══════════════════════════════════════════════════════════════
if want_phase F; then
hdr "PHASE F — resilience"

step "14. hibernation resume config"
SWAP_DEV="/dev/$VG/lv_swap"
if [[ -b "$SWAP_DEV" ]]; then
  SWAP_UUID=$(blkid -s UUID -o value "$SWAP_DEV" 2>/dev/null || true)
  if grep -q "resume=UUID=$SWAP_UUID" /etc/default/grub 2>/dev/null; then skip; else
    if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] set resume=UUID=$SWAP_UUID"; else
      cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
      sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 resume=UUID=$SWAP_UUID\"|" /etc/default/grub
      echo "RESUME=UUID=$SWAP_UUID" > /etc/initramfs-tools/conf.d/resume
      update-grub >/dev/null 2>&1
      update-initramfs -u -k all >/dev/null 2>&1
      ok; REBOOT_NEEDED=1
    fi
  fi
else yellow "no swap LV"; fi

step "    hibernate on critical battery"
if grep -q 'CriticalPowerAction=Hibernate' /etc/UPower/UPower.conf 2>/dev/null; then skip; else
  if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] UPower CriticalPowerAction=Hibernate"; else
    sed -i 's/^CriticalPowerAction=.*/CriticalPowerAction=Hibernate/' /etc/UPower/UPower.conf 2>/dev/null \
      || echo 'CriticalPowerAction=Hibernate' >> /etc/UPower/UPower.conf
    systemctl restart upower >/dev/null 2>&1 && ok || yellow "upower restart failed"
  fi
fi

step "15. Timeshift installed"
if dpkg -s timeshift &>/dev/null; then skip; else
  run apt-get install -y -qq timeshift && ok || red "FAILED"
fi
NOTES+=("Configure Timeshift (RSYNC mode). Do NOT target the same volume as / — use lv_home or external media.")

step "16. journald size cap"
if grep -qE '^SystemMaxUse=200M' /etc/systemd/journald.conf; then skip; else
  if [[ $DRY -eq 1 ]]; then echo; echo "    [dry-run] SystemMaxUse=200M"; else
    sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
    systemctl restart systemd-journald >/dev/null 2>&1 && ok || red "FAILED"
  fi
fi
fi

# ═══ PHASE G ═══════════════════════════════════════════════════════════════
if want_phase G; then
hdr "PHASE G — validation"

echo
printf '  %-34s %s\n' "sector size (expect 4096):" "$(blockdev --getss /dev/nvme0n1 2>/dev/null)"
printf '  %-34s %s\n' "LUKS:" "$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null | awk '/Version/{v=$2} /Cipher:/{c=$2} END{print "v"v" "c}')"
printf '  %-34s %s\n' "LVM free reserve:" "$(vgs --noheadings -o vg_free "$VG" 2>/dev/null | xargs)"
printf '  %-34s %s\n' "fstrim.timer:" "$(systemctl is-enabled fstrim.timer 2>/dev/null)"
printf '  %-34s %s\n' "GDS mitigation:" "$(cat /sys/devices/system/cpu/vulnerabilities/gather_data_sampling 2>/dev/null)"
printf '  %-34s %s\n' "Secure Boot:" "$(mokutil --sb-state 2>/dev/null | head -1)"
printf '  %-34s %s\n' "charge stop threshold:" "$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null)"
echo
echo "  swap topology (zram should be priority 100, above the disk swap):"
swapon --show 2>/dev/null | sed 's/^/    /'
echo
echo "  SSD health:"
smartctl -a /dev/nvme0n1 2>/dev/null | grep -E 'Percentage Used|Available Spare:|Media and Data|Unsafe Shutdowns' | sed 's/^/    /'
fi

# ═══ SUMMARY ═══════════════════════════════════════════════════════════════
hdr "SUMMARY"
if [[ ${#NOTES[@]} -eq 0 ]]; then
  green "  Nothing outstanding."
else
  for n in "${NOTES[@]}"; do echo "  • $n"; done
fi

echo
if [[ $REBOOT_NEEDED -eq 1 ]]; then
  yellow "  REBOOT REQUIRED for microcode / initramfs / TPM changes to take effect."
fi

cat <<'EOF'

  Hardware items no software step can address:
    F-01  Battery at ~23.6% of design health — replace it.
          Caused the 26 unsafe shutdowns that corrupted the previous
          filesystem. ext4 recovers faster than NTFS did, but is not immune.
    F-09  AC adapter negotiating 45 W on a 65 W platform — verify the label.

  Re-check in a month; the count should still be 26:
    sudo smartctl -a /dev/nvme0n1 | grep 'Unsafe Shutdowns'

EOF
