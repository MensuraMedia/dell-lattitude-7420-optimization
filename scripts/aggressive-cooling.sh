#!/usr/bin/env bash
#
# aggressive-cooling.sh — Dell Latitude 7420 (Tiger Lake i5-1145G7 / Iris Xe)
#
# Maximum-airflow thermal policy, for component longevity.
#
# RATIONALE
#   The CPU is the only component on this chassis with throttle telemetry, and it
#   never throttles (core/package throttle counters are 0, peak 66 C against a
#   ~98 C trip). But the VRM, the DRAM-less KIOXIA BG4 NVMe, the DRAM, the
#   capacitors and the battery all sit in the same airflow path and have NO
#   throttle telemetry at all. Semiconductor and electrolytic ageing follows an
#   Arrhenius relationship — very roughly, service life halves per +10 C. Moving
#   more air lowers every one of those temperatures whether or not any counter
#   ever moves. That is the whole justification for this policy.
#
# MEASURED FAN BEHAVIOUR (2026-08-15/16, BIOS 1.50.1, 8-thread sha256 burn, ON AC)
#   profile      load RPM   pkg W   pkg C   NVMe C
#   quiet          4024      11.18    55      37.9
#   cool           4288       7.96    47      36.9
#   balanced       4306      14.35    62      39.9
#   performance    4697      13.44    61      40.9    <- MAX AIRFLOW
#
#   Sustained max-RPM test on 'performance': peak 4731 RPM (98.6% of the 4800 rpm
#   DMI type-27 nominal), 0.24% variance -> mechanically healthy fan.
#
#   THE FAN IS LATE, NOT WEAK. From a true cold start on 'performance':
#     idle ~1250 RPM @ 40 C | L+22s 1558 RPM @ 70 C (peak heat, fan barely moved)
#     L+40s 3737 RPM        | L+66s 4720 RPM @ 62 C (full speed ~66s after load)
#   Package rides to 70 C before airflow meaningfully responds. This is the
#   chassis's real cooling deficiency and the EC ramp rate is not adjustable.
#
#   Idle RPM is NOT flat per profile -- earlier readings claiming that were taken
#   on a heat-soaked machine that never spun down between tests. See docs/20 §2.3.
#
#   TACHOMETER IS UNRELIABLE: fan1_input has reported 0 RPM through a 23 C rise,
#   then 4300 RPM seconds later. Corroborate with scripts/thermal-decay-test.sh,
#   which measures cooling physically and needs no fan sensor. See docs/20 §2.4.
#
#   POWER SOURCE MATTERS: on battery, TLP sets no_turbo=1 and halves MMIO PL1 to
#   15 W, so the package draws 6.76 W at 100% busy, reaches 43 C, and the fan
#   never spins. Confirm AC online:1 before any thermal test. See docs/20 §2.6.
#
#   NOTE ON 'cool': it reaches a low temperature by CUTTING PACKAGE POWER to
#   7.96 W, not by cooling harder. That starves the iGPU (throttle_reason_pl1 was
#   asserted in 13 of 20 samples during gameplay). It is a power-limiting profile
#   wearing a cooling label. 'performance' gives 68% more power headroom AND the
#   most airflow.
#
# WHAT CANNOT BE DONE
#   The EC owns the fan. Verified on this machine:
#     pwm1_enable = 0 / 2 / 3   -> REJECTED (EINVAL); only 1 is accepted
#     pwm1 write 255            -> silently ignored (reads back unchanged)
#   i8kutils drives the same SMM path and fails identically. There is no software
#   route to command the fan directly; 'performance' IS maximum fan on this
#   platform. See docs/20 for the physical options.
#
# Usage:
#   aggressive-cooling.sh on        apply max-airflow policy (persistent)
#   aggressive-cooling.sh off       restore firmware default (balanced/Optimized)
#   aggressive-cooling.sh status    full thermal report
#   aggressive-cooling.sh verify    prove max airflow is actually active
#   aggressive-cooling.sh monitor   continuous watchdog, logs excursions
#   aggressive-cooling.sh install   install systemd units for boot+resume
#
set -uo pipefail

PP=/sys/firmware/acpi/platform_profile
ATTR=/sys/class/firmware-attributes/dell-wmi-sysman/attributes/ThermalManagement
LOG=${LOG:-/var/log/aggressive-cooling.log}
PROFILE_MAX=performance          # BIOS token: UltraPerformance
PROFILE_DEFAULT=balanced         # BIOS token: Optimized

# Excursion thresholds. Deliberately well below any hardware trip — the point is
# to notice drift long before anything is in danger.
WARN_PKG_C=${WARN_PKG_C:-80}
WARN_NVME_C=${WARN_NVME_C:-65}
WARN_SKIN_C=${WARN_SKIN_C:-55}

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
say(){ printf '  %s\n' "$*"; }
ok(){  printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
bad(){ printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
hdr(){ printf '\n%s══ %s ══%s\n' "$B" "$*" "$N"; }

# The hwmon index is NOT stable across boots (observed moving 6 -> 5). Always
# resolve dell_smm by name.
hw(){ for h in /sys/class/hwmon/hwmon*; do
        [[ "$(cat "$h/name" 2>/dev/null)" == dell_smm ]] && { echo "$h"; return; }
      done; }

fan_rpm(){ local h; h=$(hw); [[ -n "$h" ]] && cat "$h/fan1_input" 2>/dev/null || echo ""; }
fan_max(){ local h; h=$(hw); [[ -n "$h" ]] && cat "$h/fan1_max"   2>/dev/null || echo ""; }
pkg_c(){  sensors 2>/dev/null | awk '/Package id 0/{gsub(/[+°C]/,"",$4);print $4;exit}'; }
nvme_c(){ sensors 2>/dev/null | awk '/Composite/{gsub(/[+°C]/,"",$2);print $2;exit}'; }
zone_c(){ for z in /sys/class/thermal/thermal_zone*; do
            [[ "$(cat "$z/type" 2>/dev/null)" == "$1" ]] && awk '{printf "%.0f",$1/1000}' "$z/temp"; done; }

logline(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | sudo tee -a "$LOG" >/dev/null 2>&1 || true; }

cmd_on(){
  hdr "Applying maximum-airflow policy"
  echo "$PROFILE_MAX" | sudo tee "$PP" >/dev/null 2>&1 \
    || { bad "profile '$PROFILE_MAX' rejected"; return 1; }
  sleep 6
  local p t
  p=$(cat "$PP"); t=$(sudo cat "$ATTR/current_value" 2>/dev/null)
  [[ "$p" == "$PROFILE_MAX" ]] && ok "platform_profile = $p" || { bad "did not take: $p"; return 1; }
  ok "BIOS token       = ${t:-<root-only>}  (persists in NVRAM across reboot/resume)"
  ok "fan              = $(fan_rpm) RPM of $(fan_max) max"
  logline "ON  profile=$p token=$t fan=$(fan_rpm) pkg=$(pkg_c)C nvme=$(nvme_c)C"
  cmd_verify
}

cmd_off(){
  hdr "Restoring firmware default"
  echo "$PROFILE_DEFAULT" | sudo tee "$PP" >/dev/null 2>&1 || { bad "rejected"; return 1; }
  sleep 4
  ok "platform_profile = $(cat $PP)"
  logline "OFF profile=$(cat $PP) fan=$(fan_rpm)"
}

cmd_verify(){
  hdr "Verification — is maximum airflow genuinely active?"
  local p rpm mx pct
  p=$(cat "$PP"); rpm=$(fan_rpm); mx=$(fan_max)
  [[ "$p" == "$PROFILE_MAX" ]] && ok "profile is '$PROFILE_MAX'" || bad "profile is '$p', expected '$PROFILE_MAX'"
  # The tachometer is unreliable on this platform (docs/20 §2.4): it has reported
  # 0 RPM through a 23 C rise, then 4300 RPM seconds later. Sample several times
  # and interpret against temperature and load rather than trusting one read.
  if [[ -n "$mx" && "$mx" -gt 0 ]]; then
    local samples="" best=0 r
    for _ in 1 2 3 4 5; do
      r=$(fan_rpm); samples="$samples ${r:-0}"
      [[ "${r:-0}" -gt "$best" ]] && best=$r
      sleep 1
    done
    local t; t=$(pkg_c); t=${t%.*}
    pct=$(python3 -c "print(f'{$best/$mx*100:.1f}')" 2>/dev/null)
    say "fan samples:$samples  (best $best / $mx RPM = ${pct}%)"
    say "package: ${t}C"
    if   [[ "$best" -ge 4600 ]]; then ok "fan is in the max-airflow band (>=4600 RPM)"
    elif [[ "${t:-0}" -lt 55 ]]; then
      ok "fan low, but package is only ${t}C — the EC has nothing to remove yet."
      say "  This is CORRECT behaviour, not a fault. The fan ramps with heat and"
      say "  reaches full speed ~66s after sustained load (docs/20 §2.3)."
    elif [[ "$best" -eq 0 ]]; then
      warn "all samples read 0 at ${t}C — likely the known tachometer fault (docs/20 §2.4)"
      say "  Confirm with scripts/thermal-decay-test.sh, which needs no fan sensor."
    else warn "fan $best RPM at ${t}C — below expectation; verify with thermal-decay-test.sh"; fi
  fi
  say ""
  say "direct fan control (expected to fail — recorded for completeness):"
  local h; h=$(hw)
  if [[ -n "$h" ]]; then
    local before after
    before=$(cat "$h/pwm1" 2>/dev/null)
    echo 255 2>/dev/null | sudo tee "$h/pwm1" >/dev/null 2>&1
    after=$(cat "$h/pwm1" 2>/dev/null)
    [[ "$before" == "$after" ]] \
      && say "  pwm1 write ignored (EC owns the fan) — as expected" \
      || warn "  pwm1 CHANGED ($before -> $after) — EC behaviour differs from the 2026-08-15 baseline"
  fi
}

cmd_status(){
  hdr "Thermal status"
  printf '  %-22s %s\n' "platform_profile"  "$(cat $PP 2>/dev/null)"
  printf '  %-22s %s\n' "BIOS token"        "$(sudo cat $ATTR/current_value 2>/dev/null || echo '<root-only>')"
  printf '  %-22s %s / %s RPM\n' "fan"      "$(fan_rpm)" "$(fan_max)"
  echo
  printf '  %-22s %-8s %s\n' COMPONENT TEMP LIMIT
  printf '  %-22s %-8s %s\n' "CPU package"  "$(pkg_c)C"        "100C (trip ~98C)"
  printf '  %-22s %-8s %s\n' "NVMe (BG4)"   "$(nvme_c)C"       "82.8C (crit 86.8C)"
  printf '  %-22s %-8s %s\n' "skin (TSKN)"  "$(zone_c TSKN)C"  "60C trip"
  printf '  %-22s %-8s %s\n' "memory (TMEM)" "$(zone_c TMEM)C" "60C trip"
  printf '  %-22s %-8s %s\n' "M.2 area (NGFF)" "$(zone_c NGFF)C" "60C trip"
  echo
  printf '  %-22s core=%s package=%s\n' "throttle counters" \
    "$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null)" \
    "$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count 2>/dev/null)"
  local g=/sys/class/drm/card1/gt/gt0
  if [[ -d "$g" ]]; then
    printf '  %-22s ' "GPU throttle reasons"
    for f in pl1 pl2 pl4 thermal vr_tdc; do printf '%s=%s ' "$f" "$(cat "$g/throttle_reason_$f" 2>/dev/null)"; done
    echo
  fi
}

cmd_monitor(){
  hdr "Thermal watchdog — logging to $LOG (Ctrl-C to stop)"
  say "warn thresholds: pkg ${WARN_PKG_C}C · NVMe ${WARN_NVME_C}C · skin ${WARN_SKIN_C}C"
  logline "MONITOR start profile=$(cat $PP)"
  local pk nv sk rpm
  while true; do
    pk=$(pkg_c); nv=$(nvme_c); sk=$(zone_c TSKN); rpm=$(fan_rpm)
    [[ -n "$pk" && "${pk%.*}" -ge "$WARN_PKG_C"  ]] && { warn "pkg ${pk}C >= ${WARN_PKG_C}C (fan ${rpm})"; logline "EXCURSION pkg=${pk}C fan=${rpm}"; }
    [[ -n "$nv" && "${nv%.*}" -ge "$WARN_NVME_C" ]] && { warn "NVMe ${nv}C >= ${WARN_NVME_C}C (fan ${rpm})"; logline "EXCURSION nvme=${nv}C fan=${rpm}"; }
    [[ -n "$sk" && "${sk%.*}" -ge "$WARN_SKIN_C" ]] && { warn "skin ${sk}C >= ${WARN_SKIN_C}C (fan ${rpm})"; logline "EXCURSION skin=${sk}C fan=${rpm}"; }
    # Re-assert the profile if something else changed it (TLP, power-profiles-daemon, a GUI).
    if [[ "$(cat $PP)" != "$PROFILE_MAX" ]]; then
      warn "profile drifted to '$(cat $PP)' — re-asserting $PROFILE_MAX"
      logline "DRIFT re-asserting $PROFILE_MAX (was $(cat $PP))"
      echo "$PROFILE_MAX" | sudo tee "$PP" >/dev/null 2>&1
    fi
    sleep "${MONITOR_INTERVAL:-30}"
  done
}

cmd_install(){
  hdr "Installing systemd units"
  local self; self=$(readlink -f "$0")
  sudo tee /etc/systemd/system/aggressive-cooling.service >/dev/null <<EOF
[Unit]
Description=Aggressive cooling — pin ACPI platform profile to '$PROFILE_MAX' (max airflow)
Documentation=file://$self
ConditionPathExists=$PP
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo $PROFILE_MAX > $PP && [ "\$(cat $PP)" = $PROFILE_MAX ]'

[Install]
WantedBy=multi-user.target
EOF
  # Resume path: the documented mechanism, NOT WantedBy=suspend.target (those
  # targets activate BEFORE sleep, not after resume).
  sudo tee /usr/lib/systemd/system-sleep/99-aggressive-cooling >/dev/null <<EOF
#!/bin/sh
case "\$1" in
  post) echo $PROFILE_MAX > $PP 2>/dev/null ;;
esac
exit 0
EOF
  sudo chmod 755 /usr/lib/systemd/system-sleep/99-aggressive-cooling
  sudo systemctl daemon-reload
  sudo systemctl enable --now aggressive-cooling.service >/dev/null 2>&1
  ok "aggressive-cooling.service enabled"
  ok "resume hook: /usr/lib/systemd/system-sleep/99-aggressive-cooling"
  say ""
  say "NOTE: the BIOS token persists in NVRAM on its own, so these units are"
  say "belt-and-braces against anything that rewrites the profile at runtime"
  say "(TLP, power-profiles-daemon, a desktop power applet)."
}

case "${1:-status}" in
  on)      cmd_on ;;
  off)     cmd_off ;;
  status)  cmd_status ;;
  verify)  cmd_verify ;;
  monitor) cmd_monitor ;;
  install) cmd_install ;;
  *) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \?//' ;;
esac
