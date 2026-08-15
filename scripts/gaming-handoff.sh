#!/usr/bin/env bash
#
# gaming-handoff.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# READ-ONLY state report for the gaming + cooling workstream (docs 16/17/18).
# Safe to run at any time, as many times as you like. Changes nothing by default.
#
# Answers one question: "I just rebooted — where was I, and what do I run next?"
#
# Prints:
#   1. Machine and session identity
#   2. Blocking prerequisite   (the re-login — everything else waits on it)
#   3. What is already applied (persistent vs volatile)
#   4. Gaming stack state
#   5. Measurement progress    (baseline / A/B runs captured so far)
#   6. Owner decisions still outstanding
#   7. The exact next command
#
# Usage:
#   ./gaming-handoff.sh                  # report only (read-only)
#   ./gaming-handoff.sh --apply-volatile # additionally re-apply settings that do
#                                        #   NOT survive reboot (asks first)
#
# NOTE: deliberately NOT using 'set -o pipefail' — same reason as handoff.sh:
# this script is full of '<producer> | grep -q' probes, and grep -q exiting early
# makes the producer take SIGPIPE, which pipefail would report as failure and turn
# a successful match into a false PENDING.
set -u

STATE_DIR="${STATE_DIR:-$HOME/.local/share/7420-gaming-baseline}"
LOG_DIR="$STATE_DIR/runs"
STEAMROOT="$HOME/.steam/debian-installation"
APPID=1017900
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_ID="13ef1666-bf2b-4868-ab9d-b9e784a8556a"
PP=/sys/firmware/acpi/platform_profile
APPLY=0
[[ "${1:-}" == "--apply-volatile" ]] && APPLY=1

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'

hdr()  { echo; printf '%s══ %s ══%s\n' "$B" "$*" "$N"; }
row()  { printf '  %-42s %s\n' "$1" "$2"; }
done_(){ printf '%sDONE%s' "$G" "$N"; }
pend() { printf '%sPENDING%s' "$Y" "$N"; }
blok() { printf '%sBLOCKED%s' "$R" "$N"; }
note() { printf '  %s· %s%s\n' "$C" "$*" "$N"; }
dp()   { if eval "$1" &>/dev/null; then done_; else pend; fi; }

printf '\n%s┌──────────────────────────────────────────────────────────────┐%s\n' "$B" "$N"
printf '%s│  Latitude 7420 — gaming & cooling workstream handoff          │%s\n' "$B" "$N"
printf '%s└──────────────────────────────────────────────────────────────┘%s\n' "$B" "$N"

# ─────────────────────────────────────────────────────────── 1. identity
hdr "1. Machine and session"
row "host / kernel"        "$(uname -n) / $(uname -r)"
row "BIOS"                 "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
row "uptime"               "$(uptime -p 2>/dev/null | sed 's/^up //')"
row "booted"               "$(uptime -s 2>/dev/null)"
row "repo"                 "$REPO_DIR"
row "branch"               "$(git -C "$REPO_DIR" branch --show-current 2>/dev/null)"
echo
note "resume the Claude session that produced this work:"
printf '      %scd /home/user && claude --continue%s\n' "$B" "$N"
printf '      %sclaude --resume %s%s\n' "$B" "$SESSION_ID" "$N"
note "there is no slash command for this — slash commands run INSIDE a session;"
note "resuming happens at launch. --continue is scoped to the directory it started in."

# ─────────────────────────────────────────────── 2. blocking prerequisite
hdr "2. Blocking prerequisite"
NICE_LIM=$(ulimit -e 2>/dev/null || echo 0)
IN_GRP=$(id -nG 2>/dev/null | tr ' ' '\n' | grep -qx gamemode && echo yes || echo no)
if [[ "$NICE_LIM" -ge 30 && "$IN_GRP" == yes ]]; then
  row "re-login applied (RLIMIT_NICE=$NICE_LIM)" "$(done_)"
  note "gamemode renice and Steam's thread priorities can now work"
  BLOCKED=0
else
  row "re-login applied (RLIMIT_NICE=$NICE_LIM, group=$IN_GRP)" "$(blok)"
  printf '\n  %sEVERYTHING BELOW WAITS ON THIS.%s\n' "$R" "$N"
  note "log out and back in (a reboot also works), then re-run this script."
  note "without it: gamemode's renice silently fails, and so does Steam's own"
  note "thread-priority request — you would measure a baseline that is not the"
  note "configuration you intend to ship."
  BLOCKED=1
fi

# ───────────────────────────────────────────────────── 3. applied config
hdr "3. Configuration already applied"
printf '  %s-- persistent (survives reboot) --%s\n' "$C" "$N"
row "compositor unredirect fullscreen" \
    "$(dp "[[ \$(gsettings get org.cinnamon.muffin unredirect-fullscreen-windows) == true ]]")"
row "gamemode.ini present"              "$(dp "[[ -f /etc/gamemode.ini ]]")"
row "user in gamemode group (on disk)"  "$(dp "getent group gamemode | grep -q $USER")"
row "platform_profile = $(cat $PP 2>/dev/null) (BIOS token)" \
    "$(dp "[[ -e $PP ]]")"
row "intel-gpu-tools installed"         "$(dp "command -v intel_gpu_top")"
row "libgamemodeauto0:i386 installed"   "$(dp "dpkg -l libgamemodeauto0:i386 | grep -q '^ii'")"
row "greeter background configured"     "$(dp "[[ -f /etc/lightdm/slick-greeter.conf ]]")"

printf '\n  %s-- volatile (does NOT survive reboot) --%s\n' "$C" "$N"
HWP=$(cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 2>/dev/null || echo "?")
if [[ "$HWP" == "1" ]]; then
  row "hwp_dynamic_boost = 1"           "$(done_)"
else
  row "hwp_dynamic_boost = $HWP (want 1)" "$(pend)"
  note "re-apply:  echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost"
  if [[ $APPLY -eq 1 ]]; then
    read -r -p "  re-apply hwp_dynamic_boost now? [y/N] " a </dev/tty
    [[ "$a" =~ ^[Yy] ]] && { echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost >/dev/null; \
      row "hwp_dynamic_boost re-applied" "$(done_)"; }
  fi
fi

# platform-profile unit: may be redundant; one reboot settles it
if systemctl is-enabled platform-profile-cool.service &>/dev/null; then
  ST=$(systemctl is-active platform-profile-cool.service 2>/dev/null)
  row "platform-profile-cool.service ($ST)" "$(done_)"
  note "OPEN QUESTION: the BIOS token appears self-persistent, so this unit may be"
  note "redundant. Check ThermalManagement after this boot; if it already reads the"
  note "wanted value before the unit runs, delete the unit and its sleep hook."
fi

# ────────────────────────────────────────────────────── 4. gaming stack
hdr "4. Gaming stack"
row "Steam installed"        "$(dp "command -v steam")"
if pgrep -f "$STEAMROOT/ubuntu12_32/steam" >/dev/null; then
  row "Steam running" "$(printf '%sYES — close it before setting launch options%s' "$Y" "$N")"
else
  row "Steam running" "no (ready for launch-option edit)"
fi
row "AoE:DE installed"       "$(dp "grep -q '\"StateFlags\"\s*\"4\"' $STEAMROOT/steamapps/appmanifest_$APPID.acf")"
CFG=$(ls "$STEAMROOT"/userdata/*/config/localconfig.vdf 2>/dev/null | head -1)
if [[ -n "$CFG" ]] && grep -q 'MANGOHUD=1 gamemoderun' "$CFG" 2>/dev/null; then
  row "launch options set"    "$(done_)"
else
  row "launch options set"    "$(pend)"
  note 'want:  MANGOHUD=1 gamemoderun %command%'
  note 'NOT "gamemoderun mangohud" — mangohud:i386 does not exist in noble'
fi
PAR=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)
if [[ "$PAR" -le 2 ]]; then row "perf_event_paranoid = $PAR" "$(done_)"
else row "perf_event_paranoid = $PAR (MangoHud GPU fields blank)" "$(pend)"
     note "lower to 2 for intel_gpu_top as non-root — security tradeoff, your call"; fi

# ──────────────────────────────────────────────── 5. measurement progress
hdr "5. Measurement progress"
BASE=$(ls -d "$LOG_DIR"/baseline-* 2>/dev/null | head -1)
if [[ -n "$BASE" ]]; then
  row "FPS baseline captured" "$(done_)  ($(basename "$BASE"))"
  [[ -f "$BASE/fps.txt" ]] && note "avg/1%/0.1% fps: $(cat "$BASE/fps.txt")"
else
  row "FPS baseline captured" "$(pend)"
  note "NOTHING about GPU saturation is measured yet — docs/17 labels it inference"
fi
for p in balanced cool performance; do
  row "A/B run: $p" "$(dp "[[ -d $LOG_DIR/ab-$p ]]")"
done
[[ -d "$LOG_DIR" ]] && note "raw data: $LOG_DIR"

# ─────────────────────────────────────────────────── 6. owner decisions
hdr "6. Owner decisions outstanding"
BATCFG=$(sudo cat /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg/current_value 2>/dev/null || echo "?")
BSTART=$(cat /sys/class/power_supply/BAT0/charge_control_start_threshold 2>/dev/null || echo "?")
BEND=$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null || echo "?")
BHEALTH=$(python3 -c "
try:
    cf=int(open('/sys/class/power_supply/BAT0/charge_full').read())
    cd=int(open('/sys/class/power_supply/BAT0/charge_full_design').read())
    print(f'{cf/cd*100:.1f}%')
except Exception: print('?')" 2>/dev/null)
printf '  %s%sBATTERY — highest priority, outranks every thermal change%s\n' "$B" "$R" "$N"
row "  health"                 "$BHEALTH of design"
row "  charge mode"            "$BATCFG"
row "  thresholds (sysfs)"     "$BSTART / $BEND"
note "TLP config says 95/100 but sysfs reports $BSTART/$BEND — the TLP setting is INERT,"
note "because CustomChargeStart/Stop are read-only unless PrimaryBattChargeCfg=Custom."
note "Fix: PrimaryBattChargeCfg=Custom, CustomChargeStart=55, CustomChargeStop=70"
note "Reduces unplugged runtime. See docs/17 section 6 and F-01."
echo
row "platform_profile final choice" "$(pend)"
note "cool vs performance(UltraPerformance) vs balanced — reviewers disagree and"
note "NEITHER position has valid steady-state data. Settle with the A/B, not argument."

# ──────────────────────────────────────────────────────── 7. next command
hdr "7. What to run next"
if [[ $BLOCKED -eq 1 ]]; then
  printf '  %s1.%s log out and back in  (or reboot)\n' "$B" "$N"
  printf '  %s2.%s %s%s/scripts/gaming-handoff.sh%s\n' "$B" "$N" "$B" "$REPO_DIR" "$N"
elif [[ -z "$CFG" ]] || ! grep -q 'MANGOHUD=1 gamemoderun' "${CFG:-/dev/null}" 2>/dev/null; then
  printf '  close Steam, then:\n'
  printf '  %s%s/scripts/post-reboot-gaming-baseline.sh launchopts%s\n' "$B" "$REPO_DIR" "$N"
elif [[ -z "$BASE" ]]; then
  printf '  %s%s/scripts/post-reboot-gaming-baseline.sh baseline%s\n' "$B" "$REPO_DIR" "$N"
elif [[ ! -d "$LOG_DIR/ab-performance" ]]; then
  printf '  %s%s/scripts/post-reboot-gaming-baseline.sh ab%s\n' "$B" "$REPO_DIR" "$N"
else
  printf '  %s%s/scripts/post-reboot-gaming-baseline.sh report%s\n' "$B" "$REPO_DIR" "$N"
fi
echo
note "or just run it with no argument to auto-advance through every phase:"
printf '      %s%s/scripts/post-reboot-gaming-baseline.sh%s\n' "$B" "$REPO_DIR" "$N"
echo
note "reading: docs/16 (concepts) · docs/17 (data + procedure) · docs/18 (review)"
note "PR awaiting merge: https://github.com/MensuraMedia/dell-lattitude-7420-optimization/pull/1"
echo
