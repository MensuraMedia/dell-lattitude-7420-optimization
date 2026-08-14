#!/usr/bin/env bash
#
# 01-preflight-and-upgrade.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# Stage 1 of 2. Run BEFORE any other optimization work.
#
#   1. Repoint Timeshift off /boot  (CRITICAL — see below)
#   2. Take a pre-upgrade rollback snapshot
#   3. Install git + smartmontools
#   4. Reclaim the apt archive cache
#   5. Purge the live-ISO 'casper' remnant
#   6. Ensure a LUKS header backup exists
#   7. apt full-upgrade  (406 pkgs, 290 security, microcode 0xBC->new, kernel 7.0.0-28)
#   8. Restore a usable GRUB menu timeout
#
# WHY STEP 1 IS FIRST:
#   Timeshift is currently pointed at /dev/nvme0n1p2 = /boot (1.7 GiB free) and
#   scheduled daily with 5 retained snapshots, while the root filesystem it
#   would copy is 9.1 GiB. The first run fills /boot to 100%. On a LUKS root a
#   full /boot means update-initramfs silently truncates the initramfs, and the
#   machine stops booting. Step 7 installs a new kernel, which rebuilds the
#   initramfs — so this MUST be corrected before the upgrade, not after.
#
set -uo pipefail

LUKS_PART="/dev/nvme0n1p3"
TS_CONF="/etc/timeshift/timeshift.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()   { printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
hdr()   { echo; bold "════ $* ════"; }
die()   { red "ABORT: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sudo)"

bold "Latitude 7420 — Stage 1: preflight and upgrade"
echo "  timestamp: $STAMP"

# ── 1. Timeshift: get it off /boot ────────────────────────────────────────────
hdr "1. Timeshift target"

BOOT_UUID="$(findmnt -no UUID /boot)"
HOME_UUID="$(findmnt -no UUID /home)"
echo "  /boot UUID : $BOOT_UUID"
echo "  /home UUID : $HOME_UUID  ($(findmnt -no AVAIL /home) free)"

if [[ ! -f "$TS_CONF" ]]; then
  ylw "  no $TS_CONF — nothing to repoint"
else
  CUR="$(python3 -c "import json;print(json.load(open('$TS_CONF')).get('backup_device_uuid',''))")"
  echo "  configured  : $CUR"

  if [[ "$CUR" == "$BOOT_UUID" ]]; then
    red "  MISCONFIGURED — Timeshift is targeting /boot"
    cp -a "$TS_CONF" "$TS_CONF.bak.$STAMP"

    python3 - "$TS_CONF" "$HOME_UUID" <<'PY'
import json, sys
path, uuid = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg['backup_device_uuid'] = uuid
cfg['schedule_daily']  = 'true'
cfg['count_daily']     = '3'
cfg['schedule_hourly'] = 'false'
json.dump(cfg, open(path, 'w'), indent=2)
PY
    grn "  repointed to /home (lv_home), daily x3 retained"
    echo "  backup of old config: $TS_CONF.bak.$STAMP"

    # remove the empty scaffolding Timeshift created on /boot
    if [[ -d /boot/timeshift ]]; then
      if [[ -z "$(find /boot/timeshift -mindepth 2 -maxdepth 2 -print -quit 2>/dev/null)" ]]; then
        rm -rf /boot/timeshift && grn "  removed empty /boot/timeshift scaffolding"
      else
        ylw "  /boot/timeshift is NOT empty — left in place, inspect manually"
      fi
    fi
  elif [[ "$CUR" == "$HOME_UUID" ]]; then
    grn "  already targeting /home — no change"
  else
    ylw "  targets neither /boot nor /home ($CUR) — left alone, verify manually"
  fi
fi

echo "  /boot now: $(findmnt -no USED,AVAIL,USE% /boot)"

# ── 2. Pre-upgrade rollback snapshot ─────────────────────────────────────────
hdr "2. Pre-upgrade snapshot"
if command -v timeshift >/dev/null 2>&1; then
  echo "  taking an on-demand snapshot (rollback point for the 406-package upgrade)..."
  if timeshift --create --comments "pre-upgrade $STAMP" --scripted; then
    grn "  snapshot created"
  else
    ylw "  snapshot FAILED — continuing, but you have no rollback point"
  fi
else
  ylw "  timeshift not installed — skipped"
fi

# ── 3. Tooling ────────────────────────────────────────────────────────────────
hdr "3. Tooling (git, smartmontools)"
apt-get update -qq || ylw "  apt update reported errors"
for p in git smartmontools; do
  if dpkg -s "$p" &>/dev/null; then
    echo "  $p: already installed"
  else
    if apt-get install -y -qq "$p" >/dev/null 2>&1; then grn "  $p: installed"
    else red "  $p: FAILED"; fi
  fi
done
command -v git >/dev/null && echo "  $(git --version)"

# ── 4. Reclaim apt cache ─────────────────────────────────────────────────────
hdr "4. apt cache"
BEFORE="$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1)"
apt-get clean
grn "  reclaimed $BEFORE from /var/cache/apt/archives"

# ── 5. Live-ISO remnant ──────────────────────────────────────────────────────
hdr "5. casper (live-ISO remnant)"
if dpkg -s casper &>/dev/null; then
  # only proceed if the purge touches nothing but casper-ish packages
  VICTIMS="$(apt-get -s purge casper 2>/dev/null | awk '/^Remv/{print $2}' | tr '\n' ' ')"
  echo "  purge would remove: $VICTIMS"
  if [[ "$VICTIMS" =~ ^(casper|lupin-casper|user-setup|\ )+$ ]]; then
    if apt-get purge -y -qq casper >/dev/null 2>&1; then
      grn "  purged — this also clears the failed casper-md5check.service"
    else red "  purge FAILED"; fi
  else
    ylw "  purge would remove unexpected packages — SKIPPED, review manually"
  fi
  systemctl reset-failed casper-md5check.service 2>/dev/null || true
else
  echo "  not installed"
fi

# ── 6. LUKS header backup ────────────────────────────────────────────────────
hdr "6. LUKS header backup"
HDR_DIR="/root/luks-backup"
HDR_FILE="$HDR_DIR/luks-header-$(basename "$LUKS_PART").img"
if [[ -s "$HDR_FILE" ]]; then
  echo "  present: $HDR_FILE ($(du -h "$HDR_FILE" | cut -f1))"
else
  mkdir -p "$HDR_DIR"
  if cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$HDR_FILE" 2>/dev/null; then
    chmod 600 "$HDR_FILE"; grn "  created: $HDR_FILE"
  else
    red "  FAILED to back up LUKS header"
  fi
fi
KS="$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null | grep -cE '^  [0-9]+: luks2')"
echo "  keyslots in use: ${KS:-unknown}"
[[ "${KS:-0}" -lt 2 ]] && ylw "  only one keyslot — a single forgotten passphrase means total data loss"

# ── 7. The upgrade ────────────────────────────────────────────────────────────
hdr "7. full-upgrade"
UCODE_BEFORE="$(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')"
echo "  microcode now : $UCODE_BEFORE"
echo "  GDS now       : $(cat /sys/devices/system/cpu/vulnerabilities/gather_data_sampling)"
echo "  /boot free    : $(findmnt -no AVAIL /boot)"
echo
echo "  running apt-get full-upgrade (this pulls kernel 7.0.0-28 + new microcode)..."
echo

DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  full-upgrade
RC=$?

if [[ $RC -ne 0 ]]; then
  red "  full-upgrade exited $RC — resolve before rebooting"
  ylw "  try: sudo dpkg --configure -a ; sudo apt-get -f install"
else
  grn "  upgrade complete"
fi

echo
echo "  /boot after   : $(findmnt -no USED,AVAIL,USE% /boot)"
echo "  microcode pkg : $(dpkg-query -W -f='${Version}' intel-microcode 2>/dev/null)"
if [[ -r /usr/lib/firmware/intel-ucode/06-8c-01 ]]; then
  python3 - <<'PY'
import struct
d = open("/usr/lib/firmware/intel-ucode/06-8c-01", "rb").read()
off = 0
while off < len(d):
    hv, rev, date, sig, cks, ldr, pf, dsize, tsize = struct.unpack_from("<9I", d, off)
    if hv != 1:
        break
    if sig == 0x000806C1:
        print(f"  ucode blob    : rev 0x{rev:X} for sig 0x{sig:08X}")
    off += tsize if tsize else 2048
PY
fi

# ── 8. GRUB menu access ──────────────────────────────────────────────────────
hdr "8. GRUB menu timeout"
if grep -q '^GRUB_TIMEOUT=0$' /etc/default/grub; then
  cp -a /etc/default/grub "/etc/default/grub.bak.$STAMP"
  sed -i 's/^GRUB_TIMEOUT=0$/GRUB_TIMEOUT=3/' /etc/default/grub
  sed -i 's/^GRUB_TIMEOUT_STYLE=hidden$/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
  update-grub >/dev/null 2>&1 && grn "  timeout 0 -> 3, menu visible (recovery access restored)" \
    || red "  update-grub FAILED"
else
  echo "  already non-zero: $(grep '^GRUB_TIMEOUT=' /etc/default/grub)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "SUMMARY"
echo "  Timeshift target : $(python3 -c "import json;print(json.load(open('$TS_CONF'))['backup_device_uuid'])" 2>/dev/null) (should be /home: $HOME_UUID)"
echo "  /boot            : $(findmnt -no USED,AVAIL,USE% /boot)"
echo "  kernels present  : $(ls /boot/vmlinuz-* 2>/dev/null | wc -l)"
ls /boot/vmlinuz-* 2>/dev/null | sed 's/^/    /'
echo "  pending updates  : $(apt list --upgradable 2>/dev/null | grep -c upgradable)"
echo "  failed units     : $(systemctl --failed --no-legend | wc -l)"
echo
ylw "  REBOOT NOW to load the new kernel and microcode:"
echo "      sudo reboot"
echo
echo "  Then run stage 2:  sudo bash 02-post-boot-tuning.sh"
echo
red  "  STILL MANUAL — copy the LUKS header backup to external media:"
echo "      sudo cp /root/luks-backup/luks-header-nvme0n1p3.img /media/<you>/<usb>/"
echo "  It is key material. Never commit it to git."
echo
