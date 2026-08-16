# 19 — Gaming & Cooling Runbook

**Ordered task list for the gaming and cooling workstream, from the next reboot
onward.**

Work top to bottom. The order is deliberate: it establishes **measurement before
tuning**, because the previous pass tuned first and had to retract most of its
conclusions — see [18 — Adversarial Review Log](18-adversarial-review-log.md).

Each step states **why**, the **command**, and a **verification** you can check
before moving on.

> **Mechanism:** [16 — Thermal & Power Architecture](16-thermal-and-power-architecture.md)
> **Data & procedure:** [17 — Cooling Optimization](17-cooling-optimization.md)
> **What was wrong and why:** [18 — Adversarial Review Log](18-adversarial-review-log.md)

---

## Resume the working session

There is **no slash command** for this — slash commands run *inside* a session;
resuming happens at launch.

```bash
cd /home/user && claude --continue     # most recent conversation in this directory
claude --resume 13ef1666-bf2b-4868-ab9d-b9e784a8556a
claude --resume                        # interactive picker
```

`--continue` is **directory-scoped**. Run it from `/home/user`, where the session
started, or it will not find the conversation.

---

## The two scripts

| Script | Role | Safe to re-run? |
|---|---|---|
| `scripts/gaming-handoff.sh` | **Read-only.** Where am I, what is applied, what runs next | Yes, always |
| `scripts/post-reboot-gaming-baseline.sh` | The work. Five resumable phases | Yes — skips completed phases |

Run the handoff first, every time. It selects the next command from actual system
state rather than from a fixed list, so it cannot get out of step with reality.

```bash
cd ~/dell-lattitude-7420-optimization
./scripts/gaming-handoff.sh
```

---

## Priority summary

| # | Phase | Task | Time | Why now |
|---|---|---|---|---|
| **0** | **0** | **Log out and back in** | **1 min** | **Blocks everything. `RLIMIT_NICE` stays 0 until you do.** |
| **1** | A | `gaming-handoff.sh` | 1 min | Confirms the re-login took; picks your next command |
| **2** | A | Re-apply `hwp_dynamic_boost` | 1 min | Volatile — resets to `0` on every boot |
| **3** | A | Set Steam launch options | 3 min | Steam must be **closed**, or it overwrites the edit |
| **4** | B | Capture FPS baseline | 10 min | **Nothing downstream is meaningful without it** |
| **5** | C | A/B the platform profiles | 30 min | Settles `cool` vs `performance` vs `balanced` with data |
| **6** | C | Read the report | 2 min | Compare against baseline, not against argument |
| **7** | D | Apply the winning profile | 2 min | Persist it if it differs from `cool` |
| **8** | D | Resolve `platform-profile-cool.service` | 5 min | Probably redundant; its sleep targets are wrong |
| **9** | E | **Battery charge policy** | 5 min | **Outranks every thermal change in this document** |
| **10** | E | `perf_event_paranoid` decision | 1 min | Needed for MangoHud GPU fields; security tradeoff |
| **11** | F | Load-management utility | — | Build **after** a baseline exists to validate it against |
| **12** | F | Physical: repaste + fin clean | — | Beats every software lever combined |
| **13** | F | **Replace the battery** | — | **Hardware. Nothing above substitutes.** |

---

# Phase 0 — Before anything else ⛔

## Step 0 — Log out and back in

**This blocks every other step.** A reboot works too.

Two things only take effect in a new session:

- **`gamemode` group membership** → `RLIMIT_NICE`. Without it, gamemode's `renice`
  fails silently, **and so does Steam's own thread-priority request**
  (`failed to set thread priority: setpriority() failed` appears in
  `~/.steam/debian-installation/logs/console_log.txt`).
- **`/etc/environment`** → `pam_env` applies at login only.

**Verify:**
```bash
ulimit -e          # must be 30, not 0
id -nG | tr ' ' '\n' | grep -x gamemode
gamemoded -t       # 'Verifying renice' should now pass
```

> If you skip this and measure anyway, you will produce a baseline for a
> configuration you are not shipping — and every A/B comparison built on it
> inherits the error.

---

# Phase A — Restore measurement capability

## Step 1 — Run the handoff

```bash
cd ~/dell-lattitude-7420-optimization
./scripts/gaming-handoff.sh
```

Section 2 must show `DONE`, not `BLOCKED`. Section 7 prints your next command.

## Step 2 — Re-apply the volatile setting

`hwp_dynamic_boost` is **not persistent** and returns to `0` on every boot.

```bash
./scripts/gaming-handoff.sh --apply-volatile     # asks before writing
# or directly:
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost
```

**Verify:**
```bash
cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost   # 1
```

> Why this rather than the `performance` governor: under `intel_pstate` active +
> HWP, `powersave` already permits full boost, and the `performance` governor pins
> HWP-min to max *and* forces EPP=0 — which biases the package budget toward the
> CPU and away from the iGPU. `hwp_dynamic_boost` buys wakeup latency without that
> tradeoff. See [17 §4.2](17-cooling-optimization.md).

## Step 3 — Set the Steam launch options

**Close Steam completely first.** Steam rewrites `localconfig.vdf` on exit and will
discard the edit otherwise.

```bash
./scripts/post-reboot-gaming-baseline.sh launchopts
```

The script backs up `localconfig.vdf` into
`~/.local/share/7420-gaming-baseline/` before touching it, and verifies the result.

**Verify:** Steam → *Age of Empires: Definitive Edition* → Properties → Launch Options:

```
MANGOHUD=1 gamemoderun %command%
```

> **Not** `gamemoderun mangohud %command%`. The `mangohud` wrapper preloads
> `/usr/$LIB/mangohud/libMangoHud.so`; `$LIB` expands to `i386-linux-gnu` for the
> 32-bit half of the Steam chain, and `mangohud:i386` **does not exist in Ubuntu
> noble**. Pressure-vessel imports host Vulkan implicit layers by default, so
> `MANGOHUD=1` alone activates the overlay cleanly inside the container.

---

# Phase B — Establish the baseline

## Step 4 — Capture FPS and thermals

```bash
./scripts/post-reboot-gaming-baseline.sh baseline
```

The script arms MangoHud logging, prompts you to play, samples power and thermals
in parallel, then restores `MangoHud.conf`.

**Pick one repeatable scenario and use it for every single run.** Same map, same
camera height, same unit count. An unrepeatable workload makes the entire
comparison worthless — this is the most common way an A/B like this fails.

Defaults: 120 s warm-up (discarded) + 300 s sampled. PL1 averages over **~32 s**,
so anything shorter measures the transient rather than the limit.

**Verify:**
```bash
cat ~/.local/share/7420-gaming-baseline/runs/baseline-*/fps.txt
# avg,1%low,0.1%low,samples — samples must be > 0
```

> If `fps.txt` reads `n/a,n/a,n/a,0`, MangoHud never logged. The launch options
> did not take, or `MANGOHUD=1` is missing. Fix that before continuing — every
> later phase compares against this number.

---

# Phase C — A/B the platform profiles

## Step 5 — Run each candidate

```bash
./scripts/post-reboot-gaming-baseline.sh ab
```

Tests `balanced`, `cool`, and `performance` (BIOS `UltraPerformance`), one run
each, with a 60 s cooldown between profiles. Already-captured profiles are skipped,
so you can do one per sitting:

```bash
rm -rf ~/.local/share/7420-gaming-baseline/runs/ab-cool    # to redo just that one
AB_PROFILES="cool performance" ./scripts/post-reboot-gaming-baseline.sh ab
```

The script restores your original profile on exit, **including on Ctrl-C**.

## Step 6 — Read the report

```bash
./scripts/post-reboot-gaming-baseline.sh report
```

**How to read it honestly:**

- FPS deltas inside **~3%** are noise unless your scenario was tightly repeatable.
- This machine **does not thermally throttle** — `core_throttle_count` and
  `package_throttle_count` are both `0`, with ~32 °C of headroom. A profile that
  lowers temperature is buying **component longevity, not frames**. Do not expect
  a performance delta and do not invent one.
- Watch **NVMe °C and fan RPM together**. The honest tradeoff is drive temperature
  against continuous fan bearing wear. Lower NVMe at permanently higher RPM is a
  *choice*, not a free win.
- If FPS pins at ~60 with `GFX%rc6` well above 0, you are **vsync-limited** and no
  profile will change it. Consider `fps_limit=58` in `MangoHud.conf` instead —
  it removes GPU work with no visible cost on a 60 Hz panel, which serves the
  longevity goal directly.

---

# Phase D — Decide and persist

## Step 7 — Apply the winning profile

```bash
echo <winner> | sudo tee /sys/firmware/acpi/platform_profile
```

This writes a **persistent BIOS NVRAM token** (`ThermalManagement`), so it survives
reboot and resume without help.

**Verify:**
```bash
cat /sys/firmware/acpi/platform_profile
sudo cat /sys/class/firmware-attributes/dell-wmi-sysman/attributes/ThermalManagement/current_value
```
> `current_value` is **root-readable only**. An unprivileged `cat` returns empty,
> which is easily mistaken for "unsupported".

## Step 8 — Resolve `platform-profile-cool.service`

That unit is **probably redundant** and its `WantedBy=` targets are **wrong** —
`suspend.target` and friends activate *before* sleep, not after resume.

Check whether the BIOS token already holds the value before the unit runs:

```bash
systemctl status platform-profile-cool.service   # note the timestamp
journalctl -b -u platform-profile-cool.service
```

If the token is already correct at boot, delete it:

```bash
sudo systemctl disable --now platform-profile-cool.service
sudo rm /etc/systemd/system/platform-profile-cool.service
sudo rm /usr/lib/systemd/system-sleep/99-platform-profile-cool
sudo systemctl daemon-reload
```

---

# Phase E — Owner decisions

## Step 9 — Battery charge policy 🔴

**This outranks every thermal change in this document.**

The cell is at **23.6% of design capacity** and held at **100% SoC** on AC. And the
TLP thresholds in `/etc/tlp.d/01-latitude-7420.conf` **are not being applied**:

```
config:  START_CHARGE_THRESH_BAT0=95   STOP_CHARGE_THRESH_BAT0=100
sysfs:   charge_control_start_threshold=50   end_threshold=100
```

`CustomChargeStart`/`CustomChargeStop` carry
`[ReadOnlyIfNot:PrimaryBattChargeCfg=Custom]`, and the mode is `Adaptive` — so the
custom values are read-only and TLP's setting is inert.

**Fix** (BIOS tokens via `dell-wmi-sysman`; ranges start 50–95, stop 55–100):

```bash
A=/sys/class/firmware-attributes/dell-wmi-sysman/attributes
echo Custom | sudo tee $A/PrimaryBattChargeCfg/current_value
echo 55     | sudo tee $A/CustomChargeStart/current_value
echo 70     | sudo tee $A/CustomChargeStop/current_value
```

**Verify:**
```bash
cat /sys/class/power_supply/BAT0/charge_control_{start,end}_threshold   # 55 / 70
```

> **This reduces unplugged runtime** and is an owner decision. It protects the
> *replacement* battery as much as the current one. See
> [F-01](07-findings-and-risks.md#f-01) and
> [05 — Post-Install Optimization](05-post-install-optimization.md).

## Step 10 — `perf_event_paranoid` decision

MangoHud reads Intel GPU load/clock/power by **spawning `intel_gpu_top`**, which
needs `perf_event_paranoid ≤ 2` or root. It is currently `4`, so `gpu_stats`,
`gpu_core_clock` and `gpu_power` stay blank.

```bash
# temporary (this boot only)
echo 2 | sudo tee /proc/sys/kernel/perf_event_paranoid
# persistent
echo 'kernel.perf_event_paranoid=2' | sudo tee /etc/sysctl.d/60-perf.conf
```

> This loosens **unprivileged perf access system-wide**. On a machine whose
> documentation otherwise takes hardening seriously, that is a real tradeoff —
> decide deliberately. Skipping it costs only the GPU columns in the overlay.

Also remove `throttling_status` from `~/.config/MangoHud/MangoHud.conf` — it is
**AMD-only** and does nothing on Intel.

---

# Phase F — After the baseline exists

## Step 11 — Load-management utility

Deliberately deferred until a baseline exists to validate it against. The
reconnaissance is done — real targets on this machine:

| Target | Observed |
|---|---|
| `clamav-weekly-scan.timer` | Full-filesystem AV scan; heavy I/O + CPU |
| `plocate-updatedb.timer` | Filesystem indexing |
| `apt-daily` / `apt-daily-upgrade` | Package work mid-game |
| `fwupd-refresh.timer` | Firmware metadata refresh |
| `e2scrub_all`, `fstrim`, `man-db`, `dpkg-db-backup` | Periodic maintenance |
| `/etc/cron.d/timeshift-hourly` | Snapshot mid-game = I/O spike |
| Steam client | **~34% CPU idle**, plus ~16% across three `steamwebhelper` |

Mechanism: gamemode's `[custom]` hook, which fires automatically on game start and
exit — no new daemon.

```ini
[custom]
start=/usr/local/bin/perfmode on
end=/usr/local/bin/perfmode off
```

Requirements: **stop** (never `disable`) the timers, record prior state, restore
reliably even if the game crashes, and be idempotent. Note that most of these
timers are `Persistent=yes`, so they will fire on restore if overdue — acceptable,
but expect it.

> Build this **after** Step 4, so its effect can be measured rather than assumed.
> The last attempt to reason about background load without a baseline concluded
> the compositor was irrelevant. It was the single largest factor.

## Step 12 — Physical maintenance

A five-year-old chassis with a fan at high duty will have a loaded fin stack, and
its thermal paste is past pump-out. **Repaste plus a fin-stack clean beats every
software lever in this document combined.**

Note that a high-airflow profile *accelerates* dust ingestion — a real longevity
cost of that choice.

## Step 13 — Replace the battery 🔴

Hardware. Nothing above substitutes for it. See
[F-01](07-findings-and-risks.md#f-01).

---

## Acceptance criteria

The workstream is complete when all of the following hold:

```bash
ulimit -e                                          # 30
gamemoded -t                                       # all subtests pass
cat ~/.local/share/7420-gaming-baseline/runs/baseline-*/fps.txt   # samples > 0
ls ~/.local/share/7420-gaming-baseline/runs/       # baseline + 3 ab-* runs
cat /sys/class/power_supply/BAT0/charge_control_end_threshold     # decided
cat /sys/firmware/acpi/platform_profile            # chosen from data, not argument
```

Plus: [17 §8](17-cooling-optimization.md) open questions answered, or explicitly
closed as won't-fix with a reason recorded in
[10 — Change Log](10-change-log.md).
