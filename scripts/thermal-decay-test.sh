#!/usr/bin/env bash
# Thermal decay test — measures COOLING PERFORMANCE, not fan RPM.
#
# Rationale: the tachometer has produced inconsistent readings (0 RPM during a
# 23 C temperature rise, then 4300 RPM moments later). Rather than trust it, this
# measures the physical quantity that actually matters: how fast heat leaves the
# package once the load is removed. That is a direct consequence of airflow and
# needs no fan sensor at all.
#
# Method per profile:
#   1. load to a stable hot plateau
#   2. cut the load instantly
#   3. log temperature every second through the decay
#   4. report time to fall through fixed thresholds + the initial slope
#
# A profile moving more air will show a steeper decay. If two profiles decay
# identically, their airflow is equivalent regardless of what RPM is reported.
set -u
PP=/sys/firmware/acpi/platform_profile
HW=$(for h in /sys/class/hwmon/hwmon*; do [[ "$(cat $h/name 2>/dev/null)" == dell_smm ]] && echo "$h"; done | head -1)
ORIG=$(cat $PP)
HEAT_SECS=${HEAT_SECS:-100}
DECAY_SECS=${DECAY_SECS:-70}
trap 'pkill -x sha256sum 2>/dev/null; echo "$ORIG" | sudo tee $PP >/dev/null 2>&1' EXIT

tc(){ sensors 2>/dev/null | awk '/Package id 0/{gsub(/[+°C]/,"",$4);print $4;exit}'; }
rpm(){ cat "$HW/fan1_input" 2>/dev/null; }

decay_run(){
  local prof="$1"
  echo "── profile: $prof ──"
  echo "$prof" | sudo tee $PP >/dev/null; sleep 5

  # heat to a plateau
  for i in $(seq 8); do sha256sum /dev/zero & done
  sleep "$HEAT_SECS"
  local hot rpm_hot; hot=$(tc); rpm_hot=$(rpm)
  echo "  hot plateau: ${hot}C  (tach reports ${rpm_hot} RPM)"

  # cut load, log the decay
  pkill -x sha256sum 2>/dev/null
  local series="" t=0
  while [[ $t -lt $DECAY_SECS ]]; do
    series="$series $(tc)"
    sleep 1; t=$((t+1))
  done
  echo "$prof|$hot|$rpm_hot|$series" >> /tmp/decay_results.txt
  echo "  decayed to: $(tc)C after ${DECAY_SECS}s"
  sleep 20   # settle before the next profile
}

: > /tmp/decay_results.txt
echo "════ THERMAL DECAY — cooling performance, tachometer-independent ════"
echo
decay_run performance
echo
decay_run quiet

echo
echo "════ ANALYSIS ════"
python3 - <<'PY'
rows=[]
for line in open('/tmp/decay_results.txt'):
    p=line.strip().split('|')
    if len(p)==4:
        rows.append((p[0], float(p[1]), p[2], [float(x) for x in p[3].split()]))
if len(rows)<2: print("  insufficient data"); raise SystemExit

print(f"  {'profile':<14}{'hot':>6}{'tach':>7}{'-5C':>7}{'-10C':>7}{'-15C':>7}{'slope C/s':>11}")
for name,hot,tach,s in rows:
    def cross(drop):
        tgt=hot-drop
        for i,v in enumerate(s):
            if v<=tgt: return f"{i}s"
        return "—"
    slope=(s[0]-s[min(9,len(s)-1)])/10 if len(s)>1 else 0
    print(f"  {name:<14}{hot:>6.0f}{tach:>7}{cross(5):>7}{cross(10):>7}{cross(15):>7}{slope:>11.2f}")
print()
a,b=rows[0],rows[1]
sa=(a[3][0]-a[3][min(9,len(a[3])-1)])/10
sb=(b[3][0]-b[3][min(9,len(b[3])-1)])/10
print(f"  initial decay slope: {a[0]} {sa:.2f} C/s  vs  {b[0]} {sb:.2f} C/s")
if sa>sb*1.25:
    print(f"  => '{a[0]}' removes heat MEASURABLY FASTER — more airflow, confirmed physically")
elif sb>sa*1.25:
    print(f"  => '{b[0]}' removes heat faster (unexpected — investigate)")
else:
    print("  => decay rates are equivalent; airflow difference is not measurable this way")
PY
