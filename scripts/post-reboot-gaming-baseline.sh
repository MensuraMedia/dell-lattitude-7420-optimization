#!/usr/bin/env bash
#
# post-reboot-gaming-baseline.sh — Dell Latitude 7420 (Tiger Lake i5-1145G7 / Iris Xe)
#
# Establishes a measured gaming baseline and then A/B tests ACPI platform profiles
# against it. Run AFTER a reboot (or at least after a fresh login), because two
# prerequisites only take effect in a new session:
#
#   * `gamemode` group membership  -> RLIMIT_NICE, without which gamemode's renice
#     silently fails (and so does Steam's own thread-priority request)
#   * any /etc/environment changes -> pam_env applies at login only
#
# Phases (resumable — state is persisted, run the script again to continue):
#
#   1 preflight      verify the session is actually ready; verify tooling
#   2 launchopts     set Steam launch options to MANGOHUD=1 gamemoderun %command%
#   3 baseline       capture FPS + thermals on the CURRENT profile
#   4 ab             repeat the capture on each candidate profile
#   5 report         compare every run against the baseline
#
# Everything is measured, nothing is assumed. See:
#   docs/19-gaming-cooling-runbook.md           (THE ORDER — start here)
#   docs/16-thermal-and-power-architecture.md   (mechanism)
#   docs/17-cooling-optimization.md             (data + procedure)
#   docs/18-adversarial-review-log.md           (why the earlier numbers were wrong)
#
# Not sure where you are? Run scripts/gaming-handoff.sh first — it reports state
# and prints the exact next command.
#
set -uo pipefail

APPID="${APPID:-1017900}"                       # Age of Empires: Definitive Edition
APPNAME="Age of Empires: Definitive Edition"
STEAMROOT="$HOME/.steam/debian-installation"
STATE_DIR="${STATE_DIR:-$HOME/.local/share/7420-gaming-baseline}"
LOG_DIR="$STATE_DIR/runs"
MH_CONF="$HOME/.config/MangoHud/MangoHud.conf"
PP=/sys/firmware/acpi/platform_profile
LAUNCH_OPTS='MANGOHUD=1 gamemoderun %command%'

# Profiles to A/B. 'cool' and 'performance' (BIOS UltraPerformance) are the two
# contested candidates; 'balanced' is the firmware default and the control.
AB_PROFILES="${AB_PROFILES:-balanced cool performance}"

# How long each measured run should last, in seconds. PL1 averages over ~32 s and
# the chassis settles slowly, so anything under ~5 min measures the transient.
RUN_SECONDS="${RUN_SECONDS:-300}"
SOAK_SECONDS="${SOAK_SECONDS:-120}"             # discarded warm-up before sampling

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ---------------------------------------------------------------- presentation
c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[36m'; c_0=$'\e[0m'
ok(){   printf '  %s✓%s %s\n' "$c_g" "$c_0" "$*"; }
bad(){  printf '  %s✗%s %s\n' "$c_r" "$c_0" "$*"; }
warn(){ printf '  %s!%s %s\n' "$c_y" "$c_0" "$*"; }
info(){ printf '  %s·%s %s\n' "$c_b" "$c_0" "$*"; }
head1(){ printf '\n%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
die(){ bad "$*"; exit 1; }

confirm(){ # confirm "prompt"  -> 0 yes / 1 no
  local a; read -r -p "  ${1} [y/N] " a </dev/tty; [[ "$a" =~ ^[Yy] ]]
}

# ------------------------------------------------------------------ phase 1
phase_preflight(){
  head1 "Phase 1 — preflight"
  local fail=0

  # The whole reason this script is "post-reboot".
  local nice_lim; nice_lim=$(ulimit -e 2>/dev/null || echo 0)
  if [[ "$nice_lim" -ge 30 ]]; then
    ok "RLIMIT_NICE = $nice_lim (gamemode renice can work)"
  else
    bad "RLIMIT_NICE = $nice_lim — you have NOT re-logged-in since joining 'gamemode'"
    info "log out and back in, then re-run this script"
    fail=1
  fi

  id -nG | tr ' ' '\n' | grep -qx gamemode \
    && ok "in 'gamemode' group" || { bad "not in 'gamemode' group: sudo usermod -aG gamemode $USER"; fail=1; }

  for b in turbostat sensors gamemoded; do
    command -v "$b" >/dev/null && ok "$b present" || { bad "$b missing"; fail=1; }
  done

  # MangoHud reads Intel GPU stats by shelling out to intel_gpu_top.
  if command -v intel_gpu_top >/dev/null; then
    ok "intel_gpu_top present"
    local par; par=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)
    [[ "$par" -le 2 ]] && ok "perf_event_paranoid = $par" \
      || warn "perf_event_paranoid = $par — MangoHud GPU fields will be EMPTY unless <=2 or run as root"
  else
    warn "intel-gpu-tools missing — MangoHud gpu_* fields will be blank (sudo apt install intel-gpu-tools)"
  fi

  [[ -r "$MH_CONF" ]] && ok "MangoHud config: $MH_CONF" || { bad "missing $MH_CONF"; fail=1; }
  [[ -w "$PP" || -e "$PP" ]] && ok "platform_profile: $(cat $PP) (choices: $(cat ${PP}_choices 2>/dev/null))" \
    || { bad "no ACPI platform_profile"; fail=1; }

  # gamemode self-test: renice is the subtest that fails pre-re-login.
  if gamemoded -t >/dev/null 2>&1; then ok "gamemoded -t passed"
  else warn "gamemoded -t reported failures (expected if RLIMIT_NICE is 0; re-check after re-login)"; fi

  [[ $fail -eq 0 ]] || die "preflight failed — resolve the above first"
  echo preflight > "$STATE_DIR/phase"
  ok "preflight complete"
}

# ------------------------------------------------------------------ phase 2
phase_launchopts(){
  head1 "Phase 2 — Steam launch options"

  local cfg; cfg=$(ls "$STEAMROOT"/userdata/*/config/localconfig.vdf 2>/dev/null | head -1)
  [[ -n "$cfg" ]] || die "localconfig.vdf not found — launch Steam once, then re-run"
  info "config: $cfg"

  if pgrep -f "$STEAMROOT/ubuntu12_32/steam" >/dev/null 2>&1; then
    bad "Steam is RUNNING — it will overwrite any edit on exit"
    info "close Steam completely, then re-run this phase"
    return 1
  fi

  if grep -q 'MANGOHUD=1 gamemoderun' "$cfg" 2>/dev/null; then
    ok "launch options already set"
    echo launchopts > "$STATE_DIR/phase"; return 0
  fi

  cp -a "$cfg" "$STATE_DIR/localconfig.vdf.bak-$(date +%Y%m%d-%H%M%S)"
  ok "backed up localconfig.vdf into $STATE_DIR"

  APPID="$APPID" LAUNCH_OPTS="$LAUNCH_OPTS" python3 - "$cfg" <<'PY'
import os, re, sys
path   = sys.argv[1]
appid  = os.environ["APPID"]
opts   = os.environ["LAUNCH_OPTS"]
src    = open(path, encoding="utf-8", errors="surrogateescape").read()

# Locate the "<appid>" block inside "apps" and set/replace its LaunchOptions.
m = re.search(r'(^([\t ]*)"%s"\s*\r?\n\2\{)' % re.escape(appid), src, re.M)
if not m:
    print("APPBLOCK_NOT_FOUND"); sys.exit(2)
start = m.end(); indent = m.group(2) + "\t"
depth, i = 1, start
while i < len(src) and depth:
    if src[i] == "{": depth += 1
    elif src[i] == "}": depth -= 1
    i += 1
block, end = src[start:i-1], i-1

if re.search(r'"LaunchOptions"', block):
    block = re.sub(r'("LaunchOptions"\s*)"(?:[^"\\]|\\.)*"',
                   lambda _: '"LaunchOptions"\t\t"%s"' % opts.replace('\\','\\\\').replace('"','\\"'),
                   block, count=1)
else:
    block = block.rstrip("\r\n ") + '\n%s"LaunchOptions"\t\t"%s"\n' % (
        indent, opts.replace('\\','\\\\').replace('"','\\"'))

open(path, "w", encoding="utf-8", errors="surrogateescape").write(src[:start] + block + src[end:])
print("OK")
PY
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    warn "app block for $APPID not found in localconfig.vdf"
    info "set it by hand: Steam > $APPNAME > Properties > Launch Options:"
    info "    $LAUNCH_OPTS"
    return 1
  fi
  [[ $rc -eq 0 ]] || die "failed to edit localconfig.vdf (a backup is in $STATE_DIR)"

  grep -q 'MANGOHUD=1 gamemoderun' "$cfg" \
    && ok "launch options written and verified" \
    || die "edit did not verify — restore from $STATE_DIR and set by hand"
  echo launchopts > "$STATE_DIR/phase"
}

# --------------------------------------------------------- measurement engine
# Samples thermals/power for the duration of a run, in parallel with MangoHud.
sample_thermals(){ # sample_thermals <outfile> <seconds>
  local out="$1" secs="$2" hw fan end
  hw=$(for h in /sys/class/hwmon/hwmon*; do [[ "$(cat $h/name 2>/dev/null)" == dell_smm ]] && echo "$h"; done | head -1)
  echo "epoch,pkg_w,cor_w,gfx_w,pkg_c,gfx_mhz,rc6,fan_rpm,nvme_c,tskn_c" > "$out"
  end=$(( $(date +%s) + secs ))
  while [[ $(date +%s) -lt $end ]]; do
    # turbostat: one 5s interval, parsed BY COLUMN NAME (order varies with flags)
    local line
    line=$(sudo turbostat --num_iterations 1 --interval 5 --quiet \
             --show PkgWatt,CorWatt,GFXWatt,PkgTmp,GFXMHz,GFX%rc6 2>/dev/null \
           | awk 'NR==1{for(i=1;i<=NF;i++)c[$i]=i;next}
                  $(c["PkgWatt"])+0>0{printf "%s,%s,%s,%s,%s,%s",
                     $(c["PkgWatt"]),$(c["CorWatt"]),$(c["GFXWatt"]),
                     $(c["PkgTmp"]),$(c["GFXMHz"]),$(c["GFX%rc6"]); exit}')
    fan=$([[ -n "$hw" ]] && cat "$hw/fan1_input" 2>/dev/null || echo "")
    local nvme tskn
    nvme=$(sensors 2>/dev/null | awk '/Composite/{gsub(/[+°C]/,"",$2);print $2;exit}')
    tskn=$(for z in /sys/class/thermal/thermal_zone*; do
             [[ "$(cat $z/type 2>/dev/null)" == TSKN ]] && awk '{print $1/1000}' "$z/temp"; done | head -1)
    [[ -n "$line" ]] && echo "$(date +%s),$line,$fan,$nvme,$tskn" >> "$out"
  done
}

# Turns MangoHud's CSV into avg / 1% low / 0.1% low.
parse_fps(){ # parse_fps <mangohud csv>
  python3 - "$1" <<'PY'
import csv, sys
rows=[]
with open(sys.argv[1], newline='', errors='replace') as f:
    # MangoHud writes a preamble line before the real header
    lines=[l for l in f if l.strip()]
hdr=None
for i,l in enumerate(lines):
    if 'fps' in l.lower().split(',')[0:6]: hdr=i; break
if hdr is None: print("NO_FPS_COLUMN"); sys.exit(1)
rdr=csv.DictReader(lines[hdr:])
fps=[float(r['fps']) for r in rdr if r.get('fps') and r['fps'].replace('.','',1).isdigit() and float(r['fps'])>0]
if not fps: print("NO_SAMPLES"); sys.exit(1)
fps.sort()
n=len(fps)
avg=sum(fps)/n
low1=sum(fps[:max(1,n//100)])/max(1,n//100)
low01=sum(fps[:max(1,n//1000)])/max(1,n//1000)
print(f"{avg:.1f},{low1:.1f},{low01:.1f},{n}")
PY
}

# One measured run: arm MangoHud logging, prompt the operator to play, collect.
do_run(){ # do_run <label> <profile|->
  # NOTE: these must be SEPARATE statements. `local a="$1" b="$LOG_DIR/$a"` expands
  # every argument before any assignment lands, so $a is still unbound when $b is
  # built — fatal under `set -u`.
  local label="$1"
  local prof="$2"
  local rundir="$LOG_DIR/$label"
  mkdir -p "$rundir"

  if [[ "$prof" != "-" ]]; then
    echo "$prof" | sudo tee "$PP" >/dev/null 2>&1 || { bad "profile '$prof' rejected"; return 1; }
    sleep 3
    ok "platform_profile = $(cat $PP)"
  fi

  # Arm automatic logging; MangoHud.conf is restored afterwards no matter what.
  cp -a "$MH_CONF" "$rundir/MangoHud.conf.orig"
  {
    grep -vE '^(output_folder|log_duration|autostart_log|log_interval)=' "$rundir/MangoHud.conf.orig"
    echo "output_folder=$rundir"
    echo "log_duration=$RUN_SECONDS"
    echo "log_interval=100"
    echo "autostart_log=1"
  } > "$MH_CONF"

  cat <<EOF

  ${c_y}ACTION REQUIRED${c_0}
  1. Launch ${APPNAME} from Steam.
  2. Play the SAME scenario every run — same map, same camera height, same unit
     count. An unrepeatable workload makes the whole comparison meaningless.
  3. MangoHud starts logging automatically and stops after ${RUN_SECONDS}s.
     (~${SOAK_SECONDS}s of that is warm-up and is discarded.)
  4. After pressing ENTER you get a 10s countdown — ALT-TAB BACK TO THE GAME.
     A de-focused window throttles its render loop and the sample is worthless.
  5. Do not touch this terminal again until the script says it is finished.

EOF
  if [[ -r /dev/tty ]]; then
    read -r -p "  press ENTER once the game is loaded and you are IN the scenario… " _ </dev/tty
  else
    info "no tty available — starting immediately"
  fi

  # CRITICAL: the operator is looking at a terminal right now, which means the game
  # window is de-focused and most titles throttle background rendering. Sampling
  # immediately would measure a backgrounded game. Give them time to switch back.
  echo
  for i in $(seq 10 -1 1); do
    printf "\r  %sSWITCH BACK TO THE GAME NOW%s — sampling starts in %2ds " "$c_y" "$c_0" "$i"
    sleep 1
  done
  printf "\r  %-64s\n" "sampling started."

  info "sampling for ${RUN_SECONDS}s…"
  sample_thermals "$rundir/thermals.csv" "$RUN_SECONDS" &
  local sampler=$!
  wait $sampler 2>/dev/null

  cp -a "$rundir/MangoHud.conf.orig" "$MH_CONF"; ok "MangoHud.conf restored"

  local csv; csv=$(ls -t "$rundir"/*.csv 2>/dev/null | grep -v thermals | head -1)
  if [[ -z "$csv" ]]; then
    warn "no MangoHud log produced — was MANGOHUD=1 actually in the launch options?"
    echo "n/a,n/a,n/a,0" > "$rundir/fps.txt"
  else
    parse_fps "$csv" > "$rundir/fps.txt" 2>/dev/null || echo "n/a,n/a,n/a,0" > "$rundir/fps.txt"
    ok "FPS parsed from $(basename "$csv")"
  fi

  # Thermal means, skipping the soak window.
  python3 - "$rundir/thermals.csv" "$SOAK_SECONDS" > "$rundir/thermals.txt" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1])))
if not rows: print("no samples"); raise SystemExit
t0=int(rows[0]['epoch']); soak=int(sys.argv[2])
rows=[r for r in rows if int(r['epoch'])-t0>=soak] or rows
def m(k):
    v=[float(r[k]) for r in rows if r.get(k) not in (None,'','n/a')]
    return sum(v)/len(v) if v else float('nan')
print(f"pkg_w={m('pkg_w'):.2f} cor_w={m('cor_w'):.2f} gfx_w={m('gfx_w'):.2f} "
      f"pkg_c={m('pkg_c'):.0f} gfx_mhz={m('gfx_mhz'):.0f} rc6={m('rc6'):.1f} "
      f"fan={m('fan_rpm'):.0f} nvme_c={m('nvme_c'):.1f} tskn_c={m('tskn_c'):.1f} n={len(rows)}")
PY
  cat "$rundir/thermals.txt" | sed 's/^/  /'
  ok "run '$label' complete → $rundir"
}

# ------------------------------------------------------------------ phase 3
phase_baseline(){
  head1 "Phase 3 — baseline (current profile: $(cat $PP))"
  info "this is the reference every A/B run is compared against"
  do_run "baseline-$(cat $PP)" "-" || return 1
  echo baseline > "$STATE_DIR/phase"
}

# ------------------------------------------------------------------ phase 4
phase_ab(){
  head1 "Phase 4 — A/B platform profiles"
  local orig; orig=$(cat "$PP")
  # shellcheck disable=SC2064
  trap "echo '$orig' | sudo tee '$PP' >/dev/null; echo; warn 'platform_profile restored to $orig'" EXIT

  local avail; avail=$(cat "${PP}_choices" 2>/dev/null)
  for p in $AB_PROFILES; do
    grep -qw "$p" <<<"$avail" || { warn "profile '$p' unavailable — skipping"; continue; }
    [[ -d "$LOG_DIR/ab-$p" ]] && { info "ab-$p already captured — skipping (rm -rf $LOG_DIR/ab-$p to redo)"; continue; }
    head1 "profile: $p"
    do_run "ab-$p" "$p" || warn "run for '$p' did not complete"
    info "cooling down 60s before the next profile…"; sleep 60
  done

  trap - EXIT
  echo "$orig" | sudo tee "$PP" >/dev/null
  ok "platform_profile restored to $orig"
  echo ab > "$STATE_DIR/phase"
}

# ------------------------------------------------------------------ phase 5
phase_report(){
  head1 "Phase 5 — report"
  local base; base=$(ls -d "$LOG_DIR"/baseline-* 2>/dev/null | head -1)
  [[ -n "$base" ]] || die "no baseline run found — run phase 'baseline' first"

  local b_fps; b_fps=$(cut -d, -f1 "$base/fps.txt" 2>/dev/null)
  printf '\n  %-18s %8s %8s %8s %8s %7s %7s %7s\n' RUN "FPS avg" "1% low" "pkg W" "pkg °C" "fan" "NVMe" "vs base"
  printf '  %s\n' "$(printf '%.0s-' {1..80})"

  for d in "$base" "$LOG_DIR"/ab-*; do
    [[ -d "$d" ]] || continue
    local n f1 fl th pw pc fan nv delta
    n=$(basename "$d")
    f1=$(cut -d, -f1 "$d/fps.txt" 2>/dev/null); fl=$(cut -d, -f2 "$d/fps.txt" 2>/dev/null)
    th=$(cat "$d/thermals.txt" 2>/dev/null)
    pw=$(grep -o 'pkg_w=[0-9.]*' <<<"$th" | cut -d= -f2)
    pc=$(grep -o 'pkg_c=[0-9]*'  <<<"$th" | cut -d= -f2)
    fan=$(grep -o 'fan=[0-9]*'   <<<"$th" | cut -d= -f2)
    nv=$(grep -o 'nvme_c=[0-9.]*' <<<"$th" | cut -d= -f2)
    delta="—"
    if [[ "$f1" =~ ^[0-9.]+$ && "$b_fps" =~ ^[0-9.]+$ && "$d" != "$base" ]]; then
      delta=$(python3 -c "print(f'{($f1-$b_fps)/$b_fps*100:+.1f}%')" 2>/dev/null || echo "—")
    fi
    printf '  %-18s %8s %8s %8s %8s %7s %7s %7s\n' \
      "${n:0:18}" "${f1:-n/a}" "${fl:-n/a}" "${pw:-n/a}" "${pc:-n/a}" "${fan:-n/a}" "${nv:-n/a}" "$delta"
  done

  cat <<EOF

  Interpreting this table:
   * FPS deltas inside ~3% are noise unless the scenario was tightly repeatable.
   * This machine does NOT thermally throttle (throttle counters are 0), so a
     profile that lowers temperature is buying COMPONENT LONGEVITY, not frames.
   * Watch NVMe °C and fan RPM together: the honest tradeoff is drive temperature
     against continuous fan wear. Lower NVMe at permanently higher RPM is a
     choice, not a free win.
   * If FPS is pinned at ~60 with GFX%rc6 well above 0, you are vsync-limited and
     none of these profiles will change anything. Consider fps_limit=58.

  Raw data: $LOG_DIR
EOF
  echo report > "$STATE_DIR/phase"
}

# ------------------------------------------------------------------ driver
usage(){ cat <<EOF
usage: $(basename "$0") [phase]

  preflight    verify the session is ready (re-login, group, tooling)
  launchopts   set Steam launch options (Steam must be CLOSED)
  baseline     capture FPS + thermals on the current profile
  ab           A/B each candidate profile
  report       compare every run against the baseline
  status       show progress
  all          run every phase in order (default)

env: APPID=$APPID  RUN_SECONDS=$RUN_SECONDS  AB_PROFILES="$AB_PROFILES"
EOF
}

case "${1:-all}" in
  preflight)  phase_preflight ;;
  launchopts) phase_launchopts ;;
  baseline)   phase_baseline ;;
  ab)         phase_ab ;;
  report)     phase_report ;;
  status)     echo "phase: $(cat "$STATE_DIR/phase" 2>/dev/null || echo none)"; ls -1 "$LOG_DIR" 2>/dev/null | sed 's/^/  run: /' ;;
  all)        phase_preflight && phase_launchopts && phase_baseline && phase_ab && phase_report ;;
  -h|--help)  usage ;;
  *)          usage; exit 1 ;;
esac
