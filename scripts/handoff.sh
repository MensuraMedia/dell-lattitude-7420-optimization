#!/usr/bin/env bash
#
# handoff.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# READ-ONLY state verification and handoff report.
# Safe to run at any time, as many times as you like. Changes nothing.
#
# Prints:
#   1. Machine identity and boot state
#   2. Install integrity      (doc 11 acceptance criteria, PASS/FAIL)
#   3. Runbook progress       (all 18 steps, DONE/PENDING)
#   4. Capacity
#   5. Security posture
#   6. Outstanding actions, in dependency order
#
# Usage:
#   sudo /opt/dell-7420-build/handoff.sh              # print report
#   sudo /opt/dell-7420-build/handoff.sh --save       # also write timestamped copy
#
# NOTE: deliberately NOT using 'set -o pipefail'.
# This script is full of '<producer> | grep -q <pattern>' probes. grep -q exits
# on first match, the producer takes SIGPIPE, and under pipefail the whole
# pipeline reports failure — turning a successful match into a false PENDING.
# Bit us on the lsinitramfs checks, which emit thousands of lines.
set -u

LUKS_PART="/dev/nvme0n1p3"
VG="vg_mint"
BUILD_DIR="/opt/dell-7420-build"
SAVE=0
[[ "${1:-}" == "--save" ]] && SAVE=1

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'

hdr()  { echo; printf '%s══ %s ══%s\n' "$B" "$*" "$N"; }
row()  { printf '  %-38s %s\n' "$1" "$2"; }
pass() { printf '%sPASS%s' "$G" "$N"; }
fail() { printf '%sFAIL%s' "$R" "$N"; }
done_(){ printf '%sDONE%s' "$G" "$N"; }
pend() { printf '%sPENDING%s' "$Y" "$N"; }
na()   { printf '%sN/A%s' "$Y" "$N"; }

# yes/no helper -> DONE or PENDING
dp()   { if eval "$1" &>/dev/null; then done_; else pend; fi; }
pf()   { if eval "$1" &>/dev/null; then pass; else fail; fi; }

main() {
printf '%s\n' "════════════════════════════════════════════════════════════════"
printf '%s  Dell Latitude 7420 — build handoff report%s\n' "$B" "$N"
printf '  generated %s\n' "$(date -Is)"
printf '%s\n' "════════════════════════════════════════════════════════════════"

# ── 1 ────────────────────────────────────────────────────────────────────────
hdr "1. Identity and boot state"
row "model"            "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
row "serial"           "$(cat /sys/class/dmi/id/product_serial 2>/dev/null)"
row "BIOS"             "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
row "OS"               "$(. /etc/os-release; echo "$PRETTY_NAME")"
row "running kernel"   "$(uname -r)"
row "kernels in /boot" "$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | tr '\n' ' ')"
row "uptime"           "$(uptime -p)"
row "boot time"        "$(systemd-analyze 2>/dev/null | head -1)"
row "failed units"     "$(systemctl --failed --no-legend | wc -l)"
systemctl --failed --no-legend | sed 's/^/      /'

# ── 2 ────────────────────────────────────────────────────────────────────────
hdr "2. Install integrity (doc 11 acceptance criteria)"
SS="$(blockdev --getss /dev/nvme0n1 2>/dev/null)"
row "sector size = 4096"          "$(pf "[[ '$SS' == 4096 ]]")  ($SS)"
LUKSV="$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null | awk '/^Version:/{print $2}')"
LUKSC="$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null | awk '/Cipher:/{print $2; exit}')"
LUKSK="$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null | awk '/PBKDF:/{print $2; exit}')"
row "LUKS v2 / aes-xts / argon2id" "$(pf "[[ '$LUKSV' == 2 && '$LUKSC' == aes-xts-plain64 && '$LUKSK' == argon2id ]]")  (v$LUKSV $LUKSC $LUKSK)"
VGFREE="$(vgs --noheadings --units g -o vg_free "$VG" 2>/dev/null | tr -d ' g')"
row "LVM free > 50 GiB"           "$(pf "[[ ${VGFREE%%.*} -gt 50 ]]")  (${VGFREE} GiB)"
row "fstrim.timer enabled"        "$(pf "systemctl is-enabled fstrim.timer")"
DGRAN="$(lsblk -dno DISC-GRAN /dev/nvme0n1 2>/dev/null | tr -d ' ')"
row "TRIM reaches SSD"            "$(pf "[[ -n '$DGRAN' && '$DGRAN' != 0B ]]")  (gran $DGRAN, crypttab discard: $(grep -qc discard /etc/crypttab 2>/dev/null && echo yes || echo NO))"
row "crypttab entry"              "$(pf "grep -q 'UUID=' /etc/crypttab")"
row "all mounts present"          "$(pf "findmnt / >/dev/null && findmnt /home >/dev/null && findmnt /boot >/dev/null && findmnt /boot/efi >/dev/null")"
row "swap active"                 "$(pf "swapon --show | grep -q .")"
GDS="$(cat /sys/devices/system/cpu/vulnerabilities/gather_data_sampling 2>/dev/null)"
row "GDS not Vulnerable"          "$(pf "[[ '$GDS' != *Vulnerable* ]]")  ($GDS)"
row "Secure Boot enabled"         "$(pf "mokutil --sb-state 2>/dev/null | grep -qi enabled")  ($(mokutil --sb-state 2>/dev/null | head -1))"
row "TPM2 keyslot enrolled"       "$(pf "cryptsetup luksDump '$LUKS_PART' 2>/dev/null | grep -qi tpm2")"
if command -v vainfo >/dev/null 2>&1; then
  VAN="$(vainfo 2>/dev/null | grep -cE 'VAProfile(H264|HEVC|VP9|AV1)')"
  row "VA-API profiles >= 4"      "$(pf "[[ ${VAN:-0} -ge 4 ]]")  ($VAN)"
else
  row "VA-API profiles >= 4"      "$(na)  (vainfo not installed)"
fi
if command -v smartctl >/dev/null 2>&1; then
  PU="$(smartctl -a /dev/nvme0n1 2>/dev/null | awk -F: '/Percentage Used/{gsub(/[ %]/,"",$2);print $2}')"
  MDIE="$(smartctl -a /dev/nvme0n1 2>/dev/null | awk -F: '/Media and Data Integrity Errors/{gsub(/ /,"",$2);print $2}')"
  US="$(smartctl -a /dev/nvme0n1 2>/dev/null | awk -F: '/Unsafe Shutdowns/{gsub(/ /,"",$2);print $2}')"
  row "SSD used <= 10%"           "$(pf "[[ ${PU:-100} -le 10 ]]")  (${PU}%)"
  row "media integrity errors = 0" "$(pf "[[ ${MDIE:-1} -eq 0 ]]")  (${MDIE})"
  row "unsafe shutdowns (was 26)"  "${US}  <- must not be climbing"
else
  row "SSD health"                "$(na)  (smartmontools not installed)"
fi

# ── 3 ────────────────────────────────────────────────────────────────────────
hdr "3. Runbook progress (docs/11)"
echo "  Phase 0 — pre-reboot"
# precomputed: nested command substitution inside row() misparses
INITRD="/boot/initrd.img-$(uname -r)"
P0=1
grep -q 'UUID=' /etc/crypttab 2>/dev/null || P0=0
# grep -c (not -q): consumes all input, so no SIGPIPE on the producer
[[ "$(lsinitramfs "$INITRD" 2>/dev/null | grep -c 'sbin/cryptsetup')" -gt 0 ]] || P0=0
[[ "$(lsinitramfs "$INITRD" 2>/dev/null | grep -c 'sbin/lvm')" -gt 0 ]] || P0=0
row "  0. crypttab/initramfs/GRUB repair" "$(dp "[[ $P0 -eq 1 ]]")"
echo "  Phase A — security and data safety"
row "  1. intel-microcode installed"      "$(dp "dpkg -s intel-microcode")  ($(dpkg-query -W -f='${Version}' intel-microcode 2>/dev/null))"
row "     GDS mitigated"                  "$(pf "[[ '$GDS' != *Vulnerable* ]]")"
row "  2. LUKS header backup on disk"     "$(dp "[[ -s /root/luks-backup/luks-header-nvme0n1p3.img ]]")"
row "     header copy off-machine"        "MANUAL — verify on external media"
KS="$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null | grep -cE '^  [0-9]+: luks2')"
row "     second keyslot"                 "$(dp "[[ ${KS:-0} -ge 2 ]]")  ($KS keyslot(s))"
row "  3. boot chain verified"            "$(dp "findmnt / >/dev/null && findmnt /boot/efi >/dev/null")"
echo "  Phase B — storage and memory"
row "  4. fstrim.timer"                   "$(dp "systemctl is-enabled fstrim.timer")"
row "  5. noatime on / /home /boot"       "$(dp "findmnt -no OPTIONS / | grep -q noatime")"
row "  6. sysctl vm tuning"               "$(dp "[[ -f /etc/sysctl.d/99-mint-tuning.conf ]]")  (swappiness=$(sysctl -n vm.swappiness), cache_pressure=$(sysctl -n vm.vfs_cache_pressure))"
row "  7. zram"                           "$(dp "swapon --show=NAME --noheadings | grep -q zram")"
echo "  Phase C — power and thermal"
row "  8. thermald"                       "$(dp "systemctl is-active thermald")"
row "  9. TLP installed + active"         "$(dp "systemctl is-active tlp")"
row "     power-profiles-daemon masked"   "$(dp "! systemctl is-active power-profiles-daemon")"
row "     charge thresholds"              "$(cat /sys/class/power_supply/BAT0/charge_control_start_threshold 2>/dev/null)/$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null)"
echo "  Phase D — graphics and media"
row " 10. intel-media-va-driver-non-free" "$(dp "dpkg -s intel-media-va-driver-non-free")"
echo "  Phase E — boot security (ORDER: 11 -> 12 -> 13)"
row " 11. firmware updated"               "$(dp "false")  BIOS $(cat /sys/class/dmi/id/bios_version 2>/dev/null) — run fwupdmgr"
row " 12. Secure Boot enabled"            "$(dp "mokutil --sb-state 2>/dev/null | grep -qi enabled")"
row " 13. TPM auto-unlock"                "$(dp "cryptsetup luksDump '$LUKS_PART' 2>/dev/null | grep -qi tpm2")"
echo "  Phase F — resilience"
row " 14. hibernation resume="            "$(dp "grep -q resume=UUID /etc/default/grub")"
row "     UPower critical hibernate"      "$(dp "grep -q 'CriticalPowerAction=Hibernate' /etc/UPower/UPower.conf")"
row " 15. Timeshift configured"           "$(dp "[[ -f /etc/timeshift/timeshift.json ]]")"
TSU="$(python3 -c "import json;print(json.load(open('/etc/timeshift/timeshift.json')).get('backup_device_uuid',''))" 2>/dev/null)"
BOOTU="$(findmnt -no UUID /boot)"; HOMEU="$(findmnt -no UUID /home)"
if [[ "$TSU" == "$BOOTU" ]]; then row "     Timeshift target" "$(fail)  TARGETING /boot — WILL BREAK BOOT"
elif [[ "$TSU" == "$HOMEU" ]]; then row "     Timeshift target" "$(pass)  lv_home"
else row "     Timeshift target" "$TSU"; fi
row "     snapshots"                      "$(timeshift --list 2>/dev/null | awk '/snapshots/{print $1" snapshot(s)"}' | head -1)"
row " 16. journald capped"                "$(dp "grep -qE '^SystemMaxUse=' /etc/systemd/journald.conf")  (using $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1))"

# ── 4 ────────────────────────────────────────────────────────────────────────
hdr "4. Capacity"
df -hT -x tmpfs -x devtmpfs -x efivarfs -x squashfs 2>/dev/null | sed 's/^/  /'
echo
vgs --units g 2>/dev/null | sed 's/^/  /'
lvs --units g 2>/dev/null | sed 's/^/  /'
echo
row "swap topology" ""
swapon --show 2>/dev/null | sed 's/^/      /'

# ── 5 ────────────────────────────────────────────────────────────────────────
hdr "5. Security posture"
row "pending updates"  "$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
row "AppArmor"         "$(systemctl is-active apparmor 2>/dev/null)"
# NB: the ufw UNIT can be enabled+active while the FIREWALL is inactive.
# Only 'ufw status' is authoritative. Mint ships it installed but off.
UFWRULE="$(ufw status 2>/dev/null | awk '/^Status:/{print $2}')"
row "UFW firewall"     "$(pf "[[ '$UFWRULE' == active ]]")  (ruleset: ${UFWRULE:-unknown}; unit: $(systemctl is-active ufw 2>/dev/null))"
row "LUKS keyslots"    "$(pf "[[ ${KS:-0} -ge 2 ]]")  ($KS)"
echo
echo "  CPU vulnerabilities:"
grep -H . /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null \
  | sed 's|/sys/devices/system/cpu/vulnerabilities/||' \
  | awk -F: '{printf "      %-28s %s\n", $1, substr($0, index($0,":")+1)}' \
  | grep -viE "not affected" || echo "      (all mitigated)"

# ── 6 ────────────────────────────────────────────────────────────────────────
hdr "6. Outstanding actions, in dependency order"
cat <<'EOF'
  Anything marked PENDING above is outstanding. Ordered plan:

  [1] Stage 2 — post-boot tuning            (run first, after reboot)
        sudo bash /opt/dell-7420-build/02-post-boot-tuning.sh
      Covers steps 5,6,7 (noatime/sysctl/zram), 9 (TLP), 10 (VA-API),
      14,16 (hibernate/journald). Prompts once for confirmation.

  [2] Second LUKS keyslot                   (TTY required — passphrases)
        sudo cryptsetup luksAddKey /dev/nvme0n1p3
      You currently have ONE way into this disk. Use a distinct recovery
      passphrase and store it off this machine.
      AFTER adding: refresh the header backup, it is now stale:
        sudo cryptsetup luksHeaderBackup /dev/nvme0n1p3 \
             --header-backup-file /root/luks-backup/luks-header-nvme0n1p3.img
      (delete the old file first — luksHeaderBackup will not overwrite)

  [3] Encrypted backup stick + full rsync   (TTY required — passphrase)
      Reformat the USB to LUKS+ext4, then rsync root with POSIX metadata.
      FAT32 cannot hold a restorable system image (no ownership/perms,
      4 GiB file cap) and leaves /etc/shadow and keys in the clear.

  [4] Phase E — boot security. ORDER IS LOAD-BEARING: 11 -> 12 -> 13.
      A BIOS update changes PCR 0; enabling Secure Boot changes PCR 7.
      Enrolling the TPM before either silently invalidates the binding.

        11. sudo fwupdmgr refresh --force
            sudo fwupdmgr get-updates
            sudo fwupdmgr update            # AC power required
            reboot
        12. sudo apt install --reinstall shim-signed grub-efi-amd64-signed
            sudo update-grub
            reboot -> F2 -> Secure Boot: Enabled, Mode: Deployed
            verify: mokutil --sb-state
        13. sudo /opt/dell-7420-optimization/scripts/post-boot-setup.sh --tpm
            reboot — should reach desktop with no passphrase prompt
            verify: sudo systemd-cryptenroll /dev/nvme0n1p3
      AFTER step 13 the header changes again — refresh the backup once more.

  [5] Host firewall — ufw is INSTALLED and its unit is active, but the
      ruleset is NOT enabled, so there is no firewall. Mint ships it this
      way. On a laptop that roams untrusted networks, enable it:
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        sudo ufw enable
        sudo ufw status verbose
      Check 'ufw status', never 'systemctl is-active ufw' — the unit being
      active says nothing about whether packets are being filtered.

  [6] Remove the temporary root grant when the build is finished:
        sudo rm /etc/sudoers.d/99-claude-temp
        sudo visudo -c

  KNOWN — will not resolve via software:
    GDS / Downfall. intel-microcode 3.20260210 ships revision 0xBE for
    signature 06-8C-01, which is byte-identical to what Dell BIOS 1.50.1
    already loads. apt cannot raise it. Only a BIOS update could. If none
    does, doc 11's "GDS not Vulnerable" criterion is unreachable on this
    hardware and should be amended.

    F-01  Battery ~24% of design health (14.6 Wh of 61.9 Wh). Replace.
          Charge cap left at 100 deliberately — capping a battery this
          degraded leaves under an hour. Re-run post-boot-setup.sh
          --new-battery after replacement to restore the 75/80 thresholds.
    F-09  AC adapter negotiating 45 W on a 65 W platform. Check the label.

  RECHECK IN ONE MONTH — the count must still be 26:
    sudo smartctl -a /dev/nvme0n1 | grep 'Unsafe Shutdowns'
  If it is climbing, power delivery is still failing and the battery or
  adapter is actively corrupting the filesystem.
EOF
echo
}

if [[ $SAVE -eq 1 ]]; then
  mkdir -p "$BUILD_DIR/reports"
  OUT="$BUILD_DIR/reports/handoff-$(date +%Y%m%d-%H%M%S).txt"
  main | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$OUT")
  echo "  saved: $OUT"
else
  main
fi
