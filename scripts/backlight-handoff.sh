#!/usr/bin/env bash
#
# backlight-handoff.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# Capture, verify and restore display and keyboard backlight state.
#
# Context: docs/13-display-and-keyboard-backlight.md (the incident)
#          docs/14-backlight-architecture.md        (how the stack works)
#
# The display fault this guards against was invisible to every OS-level
# indicator: sysfs reported 1023/1023 and accepted every write while the panel
# ignored all of them. Structural checks therefore CANNOT catch it. This script
# reads the panel's own DPCD registers over AUX to establish ground truth, and
# for the one criterion that only an eye can settle it asks the operator.
#
# Modes:
#   --capture   write a timestamped state snapshot (read-only)
#   --verify    check acceptance criteria as PASS/FAIL (read-only)
#   --restore   re-apply known-good BIOS keyboard settings (WRITES to NVRAM)
#   --all       capture then verify  [default]
#
# Exit: 0 all checks passed / capture succeeded
#       1 one or more checks FAILED
#       2 usage or environment error
#
set -uo pipefail

MODE="all"
OUTDIR=""
ASSUME_YES=0

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Usage: $0 [--capture|--verify|--restore|--all] [--outdir DIR] [--yes]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --capture) MODE="capture" ;;
    --verify)  MODE="verify" ;;
    --restore) MODE="restore" ;;
    --all)     MODE="all" ;;
    --outdir)  OUTDIR="${2:-}"; shift ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1"; usage ;;
  esac
  shift
done

# ── presentation ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi
hdr()  { echo; echo "${B}════ $* ════${N}"; }
row()  { printf '  %-38s %s\n' "$1" "$2"; }
pass() { printf '%s' "${G}PASS${N}"; }
fail() { printf '%s' "${R}FAIL${N}"; }
warn() { printf '%s' "${Y}WARN${N}"; }
info() { printf '%s' "----"; }

FAILED=0
check() { # check "label" "test-expression" "actual"
  if eval "$2" &>/dev/null; then row "$1" "$(pass)  ${3:-}"
  else row "$1" "$(fail)  ${3:-}"; FAILED=$((FAILED+1)); fi
}

ROOT=0; [[ $EUID -eq 0 ]] && ROOT=1
SUDO=""; [[ $ROOT -eq 0 ]] && command -v sudo >/dev/null && SUDO="sudo"

rd() { # readable-or-dash
  local f="$1"
  if [[ -r "$f" ]]; then cat "$f" 2>/dev/null
  elif [[ -n "$SUDO" ]]; then $SUDO cat "$f" 2>/dev/null || echo "-"
  else echo "-"; fi
}

BL=/sys/class/backlight/intel_backlight
KBD=/sys/class/leds/dell::kbd_backlight
FWA=/sys/class/firmware-attributes/dell-wmi-sysman/attributes
AUX=/dev/drm_dp_aux0

# ── DPCD access ──────────────────────────────────────────────────────────────
# The single source of truth. Everything above this in the stack can and did lie.
dpcd_dump() {
  [[ -e "$AUX" ]] || { echo "  (no $AUX)"; return; }
  command -v python3 >/dev/null || { echo "  (python3 unavailable)"; return; }
  ${SUDO:+$SUDO} python3 - "$AUX" <<'PY' 2>/dev/null || echo "  (DPCD read failed — needs root)"
import os, sys
p = sys.argv[1]
fd = os.open(p, os.O_RDWR)
def rd(off, n=1):
    os.lseek(fd, off, 0); return os.read(fd, n)
mode = rd(0x721)[0]
msb, lsb = rd(0x722, 2)
level = (msb << 8) | lsb
bits  = rd(0x724)[0]
freq  = rd(0x728)[0]
hdr   = rd(0x340, 16)
names = {0: "PWM pin", 2: "DPCD AUX"}
print("  0x721 BL_CONTROL_MODE      = 0x%02x  (%s)" % (mode, names.get(mode & 0x03, "mode %d" % (mode & 3))))
print("  0x722/23 brightness        = 0x%04X (%d)" % (level, level))
print("  0x724 PWMGEN_BIT_COUNT     = %d      (implies max_brightness %d)" % (bits, (1 << bits) - 1))
print("  0x728 FREQ_SET             = %d" % freq)
if freq:
    print("        -> PWM frequency     ~ %.1f Hz" % (27e6 / (freq * (1 << bits))))
print("  0x340 Intel HDR block      = %s" % ("all zero (interface UNSUPPORTED)" if not any(hdr) else hdr.hex()))
os.close(fd)
PY
}

dpcd_mode() { # prints 0x721 as decimal masked mode, or "-"
  [[ -e "$AUX" ]] || { echo "-"; return; }
  command -v python3 >/dev/null || { echo "-"; return; }
  ${SUDO:+$SUDO} python3 -c "
import os,sys
try:
    fd=os.open('$AUX',os.O_RDWR); os.lseek(fd,0x721,0)
    print('0x%02x'%os.read(fd,1)[0]); os.close(fd)
except Exception: print('-')" 2>/dev/null || echo "-"
}

# ── CAPTURE ──────────────────────────────────────────────────────────────────
do_capture() {
  local stamp target
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -z "$OUTDIR" ]]; then
    OUTDIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/diagnostics"
    [[ -d "$OUTDIR" ]] || OUTDIR="$(dirname "$0")"
  fi
  mkdir -p "$OUTDIR" 2>/dev/null
  target="$OUTDIR/backlight-state-$stamp.txt"

  {
    echo "════════════════════════════════════════════════════════════════"
    echo "  Dell Latitude 7420 — backlight state snapshot"
    echo "  generated $(date -Is)"
    echo "════════════════════════════════════════════════════════════════"

    echo; echo "══ 1. Identity ══"
    row "model"        "$(rd /sys/class/dmi/id/product_name)"
    row "BIOS"         "$(rd /sys/class/dmi/id/bios_version)"
    row "kernel"       "$(uname -r)"
    row "cmdline"      "$(rd /proc/cmdline)"
    row "GRUB default" "$(grep -h '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub 2>/dev/null)"

    echo; echo "══ 2. Display backlight (sysfs) ══"
    for d in /sys/class/backlight/*/; do
      [[ -d "$d" ]] || continue
      echo "  -- $d"
      for f in type scale brightness actual_brightness max_brightness bl_power; do
        [[ -e "$d$f" ]] && row "     $f" "$(rd "$d$f")"
      done
    done

    echo; echo "══ 3. Panel DPCD (ground truth, over AUX) ══"
    dpcd_dump

    echo; echo "══ 4. i915 parameters ══"
    for p in enable_dpcd_backlight enable_psr enable_psr2_sel_fetch enable_fbc \
             enable_dc invert_brightness enable_panel_replay; do
      row "  $p" "$(rd /sys/module/i915/parameters/$p)"
    done

    echo; echo "══ 5. Keyboard backlight (kernel LED class) ══"
    for f in brightness max_brightness stop_timeout start_triggers; do
      [[ -e "$KBD/$f" ]] && row "  $f" "$(rd "$KBD/$f")"
    done

    echo; echo "══ 6. Dell BIOS attributes (authoritative over the OS) ══"
    if [[ -d "$FWA" ]]; then
      for a in "$FWA"/*; do
        n="$(basename "$a")"
        case "$n" in
          *[Kk]eyboard*|*[Kk]bd*|*[Ii]llum*|*[Bb]acklight*|PowerWarn|*[Dd]isplay*|*Thermal*)
            row "  $n" "$(rd "$a/current_value")" ;;
        esac
      done
      row "  Admin password enabled" \
          "$(rd /sys/class/firmware-attributes/dell-wmi-sysman/authentication/Admin/is_enabled)"
    else
      echo "  (dell-wmi-sysman not present)"
    fi

    echo; echo "══ 7. DRM connectors / PSR ══"
    for c in /sys/class/drm/card*-*/status; do
      [[ -e "$c" ]] && row "  ${c%/status}" "$(rd "$c")"
    done
    for f in /sys/kernel/debug/dri/*/i915_edp_psr_status; do
      [[ -e "$f" ]] && { echo "  -- PSR"; rd "$f" | sed 's/^/     /' | head -4; }
    done

    echo; echo "══ 8. X11 view (informational — can mask the truth) ══"
    if [[ -n "${DISPLAY:-}" ]] && command -v xrandr >/dev/null; then
      xrandr --verbose 2>/dev/null | grep -iE "^eDP|Brightness|Gamma|Backlight" | sed 's/^/  /'
    else
      echo "  (no DISPLAY)"
    fi

    echo; echo "══ 9. systemd saved backlight state ══"
    for f in /var/lib/systemd/backlight/*; do
      [[ -e "$f" ]] && row "  $(basename "$f")" "$(rd "$f" | tr '\n' ' ')"
    done

    echo; echo "══ 10. Power delivery (context for thermal/power theories) ══"
    for d in /sys/class/power_supply/*/; do
      t="$(rd "$d/type")"
      case "$t" in
        Mains) row "  $(basename "$d") online" "$(rd "$d/online")" ;;
        Battery)
          ef="$(rd "$d/energy_full")"; ed="$(rd "$d/energy_full_design")"
          row "  $(basename "$d") status" "$(rd "$d/status")"
          if [[ "$ef" =~ ^[0-9]+$ && "$ed" =~ ^[0-9]+$ && "$ed" -gt 0 ]]; then
            row "  $(basename "$d") health" "$(( ef * 100 / ed ))% of design"
          fi ;;
        USB)
          [[ "$(rd "$d/online")" == "1" ]] && {
            v="$(rd "$d/voltage_now")"; c="$(rd "$d/current_now")"
            [[ "$v" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] && \
              row "  $(basename "$d")" "$(( v/1000000 ))V x $(( c/1000000 ))A = $(( v/1000000 * c/1000000 ))W"
          } ;;
      esac
    done
  } | tee "$target"

  echo
  echo "${B}snapshot written:${N} $target"
}

# ── VERIFY ───────────────────────────────────────────────────────────────────
do_verify() {
  hdr "Acceptance criteria — docs/13 §5"

  local cmdline mode maxb kbdto_ac kbdto_bt kbdillum kbdto kbdbr

  cmdline="$(rd /proc/cmdline)"
  check "i915.enable_dpcd_backlight=0 on cmdline" \
        "grep -q 'i915.enable_dpcd_backlight=0' /proc/cmdline" \
        "$(grep -o 'i915.enable_dpcd_backlight=[0-9]' /proc/cmdline 2>/dev/null || echo 'absent')"

  check "parameter present in /etc/default/grub" \
        "grep -q 'i915.enable_dpcd_backlight=0' /etc/default/grub" ""

  mode="$(dpcd_mode)"
  check "panel NOT on DPCD AUX path (0x721 != 0x0a)" \
        "[[ '$mode' != '0x0a' && '$mode' != '-' ]]" \
        "0x721 = $mode"

  maxb="$(rd $BL/max_brightness)"
  if [[ "$maxb" == "1023" ]]; then
    row "max_brightness not AUX-derived (!=1023)" "$(warn)  $maxb — AUX PWMGEN value, suspicious"
  else
    row "max_brightness not AUX-derived (!=1023)" "$(pass)  $maxb"
  fi

  row "brightness / actual" "$(info)  $(rd $BL/brightness) / $(rd $BL/actual_brightness)"
  row "bl_power (0 = on)"   "$(info)  $(rd $BL/bl_power)"

  hdr "Keyboard backlight"
  kbdto_ac="$(rd $FWA/KbdBacklightTimeoutAc/current_value)"
  kbdto_bt="$(rd $FWA/KbdBacklightTimeoutBatt/current_value)"
  kbdillum="$(rd $FWA/KeyboardIllumination/current_value)"
  kbdto="$(rd $KBD/stop_timeout)"
  kbdbr="$(rd $KBD/brightness)"

  check "BIOS KbdBacklightTimeoutAc = Never"   "[[ '$kbdto_ac' == 'Never' ]]" "$kbdto_ac"
  check "BIOS KbdBacklightTimeoutBatt = Never" "[[ '$kbdto_bt' == 'Never' ]]" "$kbdto_bt"
  check "BIOS KeyboardIllumination = Dim"      "[[ '$kbdillum' == 'Dim' ]]"   "$kbdillum"
  check "driver stop_timeout propagated (63h)" "[[ '$kbdto' == '63h' ]]"      "$kbdto"
  check "keyboard LED lit (brightness >= 1)"   "[[ '${kbdbr:-0}' -ge 1 ]]"    "$kbdbr"
  row   "start_triggers (must be +, not -)"    "$(info)  $(rd $KBD/start_triggers)"

  hdr "Operator confirmation — cannot be automated"
  cat <<'EOF'
  The 2026-08-14 fault passed every structural check while the panel was
  unreadable. These two require an eye:

    1. Press Fn+F6 and Fn+F7. Does the panel brightness actually change?
    2. Is the keyboard still lit 60s after you stop typing?

  If either answer is no, the fix did not take. See docs/13 §6 for rollback.
EOF

  hdr "Result"
  if [[ $FAILED -eq 0 ]]; then
    echo "  ${G}All automated checks passed.${N} Operator confirmation still required."
  else
    echo "  ${R}$FAILED automated check(s) FAILED.${N} See docs/13 §6."
  fi
}

# ── RESTORE ──────────────────────────────────────────────────────────────────
do_restore() {
  hdr "Restore known-good keyboard backlight settings (writes to BIOS NVRAM)"

  [[ -d "$FWA" ]] || { echo "  ${R}dell-wmi-sysman not present — cannot restore${N}"; exit 2; }

  if [[ "$(rd /sys/class/firmware-attributes/dell-wmi-sysman/authentication/Admin/is_enabled)" == "1" ]]; then
    echo "  ${Y}A BIOS admin password is set.${N} These writes will be rejected."
    echo "  Set them in BIOS Setup (F2) -> System Configuration -> Keyboard Backlight."
    exit 2
  fi

  echo "  will set:"
  echo "    KbdBacklightTimeoutAc   -> Never"
  echo "    KbdBacklightTimeoutBatt -> Never"
  echo "    KeyboardIllumination    -> Dim  (lowest lit level)"
  if [[ $ASSUME_YES -eq 0 ]]; then
    read -rp "  proceed? [y/N] " a
    [[ "${a,,}" == "y" ]] || { echo "  aborted — nothing changed"; exit 0; }
  fi

  for kv in "KbdBacklightTimeoutAc=Never" "KbdBacklightTimeoutBatt=Never" \
            "KeyboardIllumination=Dim"; do
    k="${kv%%=*}"; v="${kv##*=}"
    if [[ ! -e "$FWA/$k/current_value" ]]; then
      row "$k" "$(warn)  attribute not present"; continue
    fi
    if echo -n "$v" | ${SUDO:+$SUDO} tee "$FWA/$k/current_value" >/dev/null 2>&1; then
      row "$k" "$(pass)  now $(rd "$FWA/$k/current_value")"
    else
      row "$k" "$(fail)  write rejected"; FAILED=$((FAILED+1))
    fi
  done

  echo
  echo "  These are NVRAM settings — they persist across reboots with no"
  echo "  systemd unit, udev rule or startup script."
}

# ── main ─────────────────────────────────────────────────────────────────────
echo "${B}Latitude 7420 — backlight handoff${N}   mode: $MODE   $(date -Is)"
[[ $ROOT -eq 0 && -z "$SUDO" ]] && echo "${Y}note: not root and no sudo — DPCD and some reads will be unavailable${N}"

case "$MODE" in
  capture) do_capture ;;
  verify)  do_verify ;;
  restore) do_restore ;;
  all)     do_capture; do_verify ;;
esac

exit $(( FAILED > 0 ? 1 : 0 ))
