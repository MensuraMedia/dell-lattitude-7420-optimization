#!/usr/bin/env bash
#
# lid-dock-handoff.sh — Dell Latitude 7420 / Linux Mint 22.3
#
# READ-ONLY state report for the lid / sleep / dock workstream (docs 21, 22, 23).
# Safe to run at any time, as many times as you like. Changes nothing by default.
#
# Answers one question: "I just rebooted — did everything come back, and what is
# still outstanding?"
#
# Prints:
#   1. Machine and session identity      (+ how to resume the Claude session)
#   2. Lid & sleep posture               (the thing most likely to regress)
#   3. Dock, network and display
#   4. Power                             (this machine's standing hazard)
#   5. What this session changed         (persistent vs volatile)
#   6. Outstanding decisions
#   7. The exact next command
#
# Usage:
#   ./lid-dock-handoff.sh                 # report only (read-only)
#   sudo ./lid-dock-handoff.sh --apply-lid-dropin
#                                         # install /etc/systemd/logind.conf.d/10-lid.conf
#                                         #   makes the lid inert independently of the
#                                         #   desktop session. Asks first. See docs/21 §7.
#
# NOTE: deliberately NOT using 'set -o pipefail' — same reason as handoff.sh and
# gaming-handoff.sh: this script is full of '<producer> | grep -q' probes, and
# grep -q exiting early makes the producer take SIGPIPE, which pipefail would
# report as failure and turn a successful match into a false PENDING.
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_ID="50bbaad1-0ac5-4a9e-aca1-7164bfc51aaf"
DROPIN=/etc/systemd/logind.conf.d/10-lid.conf
LOGIND="busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager"
APPLY=0
[[ "${1:-}" == "--apply-lid-dropin" ]] && APPLY=1

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'

hdr()  { echo; printf '%s══ %s ══%s\n' "$B" "$*" "$N"; }
row()  { printf '  %-42s %s\n' "$1" "$2"; }
ok()   { printf '%sOK%s' "$G" "$N"; }
warn() { printf '%sWARN%s' "$Y" "$N"; }
bad()  { printf '%sFAIL%s' "$R" "$N"; }
pend() { printf '%sPENDING%s' "$Y" "$N"; }
note() { printf '  %s· %s%s\n' "$C" "$*" "$N"; }
pf()   { if eval "$1" &>/dev/null; then ok; else bad; fi; }
dp()   { if eval "$1" &>/dev/null; then printf '%sDONE%s' "$G" "$N"; else pend; fi; }

# strip busctl's  s "value"  wrapper
lg()   { $LOGIND "$1" 2>/dev/null | sed 's/^[sb] //; s/"//g'; }
# CanSuspend/CanHibernate are METHODS on the Manager, not properties — get-property
# returns nothing for them. This bit the first draft of this script.
lgc()  { busctl call org.freedesktop.login1 /org/freedesktop/login1 \
           org.freedesktop.login1.Manager "$1" 2>/dev/null | sed 's/^s //; s/"//g'; }

printf '\n%s┌──────────────────────────────────────────────────────────────┐%s\n' "$B" "$N"
printf '%s│  Latitude 7420 — lid / sleep / dock handoff                   │%s\n' "$B" "$N"
printf '%s└──────────────────────────────────────────────────────────────┘%s\n' "$B" "$N"

# ─────────────────────────────────────────────────────────── 1. identity
hdr "1. Machine and session"
row "host / kernel"   "$(uname -n) / $(uname -r)"
row "BIOS"            "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
row "uptime"          "$(uptime -p 2>/dev/null | sed 's/^up //')"
row "booted"          "$(uptime -s 2>/dev/null)"
row "repo / branch"   "$REPO_DIR ($(git -C "$REPO_DIR" branch --show-current 2>/dev/null))"
echo
note "resume the Claude session that produced this work:"
printf '      %scd /home/user && claude --continue%s\n' "$B" "$N"
printf '      %sclaude --resume %s%s\n' "$B" "$SESSION_ID" "$N"
note "--continue is scoped to the directory the session started in (/home/user)."
note "resuming happens at launch — there is no slash command for it."

# ──────────────────────────────────────────────────── 2. lid & sleep
hdr "2. Lid and sleep posture"

for t in sleep suspend hibernate hybrid-sleep; do
  state=$(systemctl is-enabled "$t.target" 2>/dev/null)
  if [[ "$state" == "masked" ]]; then row "$t.target" "$(bad)  masked"
  else                                row "$t.target" "$(ok)  $state"; fi
done
echo
row "CanSuspend"              "$(lgc CanSuspend)"
row "CanHibernate"            "$(lgc CanHibernate)   (polkit-blocked by Ubuntu — docs/21 §6)"
row "HandleLidSwitch"         "$(lg HandleLidSwitch)"
row "HandleLidSwitchDocked"   "$(lg HandleLidSwitchDocked)"
row "Docked / LidClosed"      "$(lg Docked) / $(lg LidClosed)"
echo

if [[ -f "$DROPIN" ]]; then
  row "logind lid drop-in"    "$(ok)  installed — lid inert at greeter/TTY too"
else
  row "logind lid drop-in"    "$(warn)  absent"
  note "Without it the lid is inert ONLY while a desktop session runs."
  note "At the greeter, a TTY, or between logout and login, HandleLidSwitch=suspend applies."
  note "Install:  sudo $0 --apply-lid-dropin"
fi

if systemd-inhibit --list --no-pager 2>/dev/null | grep -q handle-lid-switch; then
  row "csd-power lid inhibitor" "$(ok)  held (session-scoped)"
else
  row "csd-power lid inhibitor" "$(warn)  not held — no desktop session?"
fi
row "cinnamon lid action (AC/bat)" \
    "$(gsettings get org.cinnamon.settings-daemon.plugins.power lid-close-ac-action 2>/dev/null | tr -d \')/$(gsettings get org.cinnamon.settings-daemon.plugins.power lid-close-battery-action 2>/dev/null | tr -d \')"
row "BIOS Power On Lid Open" \
    "$(sudo -n cat /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PowerOnLidOpen/current_value 2>/dev/null || echo '? (needs root)')"
note "PowerOnLidOpen=Enabled is WANTED here: with the lid shut the power button is"
note "unreachable, so opening the lid is the only convenient way to start the machine."

# ─────────────────────────────────────────────── 3. dock / net / display
hdr "3. Dock, network and display"
ETH=$(ls /sys/class/net | grep -E '^en' | head -1)
if [[ -n "$ETH" ]]; then
  row "ethernet iface"    "$ETH"
  row "  link"            "$(sudo -n ethtool "$ETH" 2>/dev/null | grep -oP 'Speed: \K.*' || echo '? (needs root)')"
  row "  carrier"         "$(cat /sys/class/net/$ETH/operstate 2>/dev/null)"
  row "  address"         "$(ip -br addr show "$ETH" 2>/dev/null | awk '{print $3}')"
  row "  errors rx/tx"    "$(cat /sys/class/net/$ETH/statistics/rx_errors)/$(cat /sys/class/net/$ETH/statistics/tx_errors)"
else
  row "ethernet iface"    "$(warn)  none — adapter not attached"
fi
row "default route via"   "$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')"
row "VPN (nordlynx)"      "$(ip -br addr show nordlynx 2>/dev/null | awk '{print $3}' || echo 'not present')$(ip route show table 205 2>/dev/null | grep -q '^default' && echo '  (default route -> tunnel)')"
echo
row "USB hubs attached"   "$(lsusb 2>/dev/null | grep -ci 'hub' )"
row "thunderbolt devices" "$(boltctl list 2>/dev/null | grep -c '●' || true)"
echo
for c in /sys/class/drm/card*-*/status; do
  s=$(cat "$c"); n=$(basename "${c%/status}")
  [[ "$s" == connected ]] && row "display $n" "$(ok)  connected"
done
row "active geometry"     "$(DISPLAY=:0 xrandr --query 2>/dev/null | head -1 | grep -oP 'current \K[0-9x ]+' || echo '?')"
note "layout persists via ~/.config/cinnamon-monitors.xml — verify it survived this boot."

# ─────────────────────────────────────────────────────────── 4. power
hdr "4. Power  — this machine's standing hazard"
AC=$(cat /sys/class/power_supply/AC/online 2>/dev/null)
CAP=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
ST=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
if [[ "$AC" == "1" ]]; then row "AC adapter" "$(ok)  online"
else                        row "AC adapter" "$(bad)  OFFLINE — running on battery"; fi
row "battery"  "$CAP% ($ST)"
row "health"   "23.6% of design capacity — see F-01 in docs/07"
echo
note "The USB-C hub is PASSIVE: no Power Delivery, and the laptop sits in"
note "power_role=source, i.e. it FEEDS the dock. It can never charge you."
note "Treat the barrel charger as part of the dock, not an optional extra."
[[ "$AC" != "1" ]] && printf '  %s%sPLUG IN THE CHARGER — ~20 min of runtime at this health level.%s\n' "$B" "$R" "$N"

# ────────────────────────────────────────────── 5. what changed
hdr "5. What the 2026-08-22 session changed"
printf '  %s-- persistent (survives reboot) --%s\n' "$C" "$N"
row "sleep targets unmasked"       "$(dp '! systemctl is-enabled sleep.target 2>/dev/null | grep -q masked')"
row "logind lid drop-in"           "$(dp "test -f $DROPIN")"
row "docs 21/22/23 on main"        "$(dp "test -f $REPO_DIR/docs/21-lid-power-and-sleep.md -a -f $REPO_DIR/docs/22-drive-migration.md -a -f $REPO_DIR/docs/23-camera-and-imaging.md")"
row "display layout saved"         "$(dp 'test -f $HOME/.config/cinnamon-monitors.xml')"
printf '\n  %s-- NOT changed, deliberately --%s\n' "$C" "$N"
note "PowerOnLidOpen — still Enabled (wanted, see §2)"
note "Cinnamon lid action — still 'blank', not 'suspend'"
note "Hibernate — still polkit-blocked; override drafted in docs/21 §6, not applied"

# ────────────────────────────────────────────── 6. outstanding
hdr "6. Outstanding"
printf '  %s%s[HIGH]%s  Suspend has NEVER been exercised on this install.\n' "$B" "$Y" "$N"
note "CanSuspend=yes proves it is permitted, not that s2idle resumes cleanly"
note "under LUKS with i915.enable_dpcd_backlight=0. Test: systemctl suspend"
note "from a clean desktop, then confirm the panel returns. docs/13 has the"
note "backlight regression most likely to interact."
echo
printf '  %s[MED]%s   Battery at 23.6%% health — replacement outranks every other change.\n' "$Y" "$N"
printf '  %s[MED]%s   SSD is DRAM-less; slot is PCIe 4.0 x4. Migration: docs/22.\n' "$Y" "$N"
printf '  %s[LOW]%s   Hibernate: apply the polkit rule and test, or record the decision not to.\n' "$Y" "$N"
printf '  %s[LOW]%s   Audit the undocumented 2026-08-16 23:29 mask session for other changes.\n' "$Y" "$N"

# ────────────────────────────────────────────── 7. next command
hdr "7. Next"
if [[ ! -f "$DROPIN" ]]; then
  printf '      %ssudo %s --apply-lid-dropin%s\n' "$B" "$0" "$N"
else
  printf '      %s# lid posture is complete. Next: prove suspend works.%s\n' "$C" "$N"
  printf '      %ssystemctl suspend%s   %s(from a clean desktop, then check the panel returns)%s\n' "$B" "$N" "$C" "$N"
fi
echo

# ────────────────────────────────────────────── optional: apply drop-in
if (( APPLY )); then
  hdr "Applying logind lid drop-in"
  if [[ $EUID -ne 0 ]]; then
    printf '  %sNeeds root. Re-run: sudo %s --apply-lid-dropin%s\n\n' "$R" "$0" "$N"; exit 1
  fi
  if [[ -f "$DROPIN" ]]; then
    printf '  Already present at %s — nothing to do.\n\n' "$DROPIN"; exit 0
  fi
  printf '  Will write %s:\n\n' "$DROPIN"
  printf '      [Login]\n      HandleLidSwitch=ignore\n      HandleLidSwitchDocked=ignore\n      HandleLidSwitchExternalPower=ignore\n\n'
  printf '  Effect: the lid stops being a suspend trigger at EVERY stage — greeter,\n'
  printf '  TTY, and between logout and login — not just inside a desktop session.\n'
  printf '  Suspend stays available on demand. Reversible: delete the file.\n\n'
  read -rp "  Proceed? [y/N] " a
  [[ "${a,,}" == y ]] || { printf '  Aborted.\n\n'; exit 0; }
  mkdir -p "$(dirname "$DROPIN")"
  cat > "$DROPIN" <<'DROPEOF'
# Latitude 7420 — lid is inert; the machine lives docked with the lid closed.
# See docs/21-lid-power-and-sleep.md §7.
#
# Without this the lid is inert only while a desktop session runs (csd-power
# holds a handle-lid-switch inhibitor). At the LightDM greeter, on a TTY, or
# between logout and login there is no inhibitor and logind's default
# HandleLidSwitch=suspend applies. Suspend was masked until 2026-08-22, which
# hid that gap; unmasking made it live.
#
# Suspend remains available on demand. Only the lid stops being a trigger.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
DROPEOF
  printf '  %sWritten.%s Active after the next reboot, or immediately with:\n' "$G" "$N"
  printf '      %ssystemctl restart systemd-logind%s  %s(can end the graphical session)%s\n\n' "$B" "$N" "$Y" "$N"
fi
