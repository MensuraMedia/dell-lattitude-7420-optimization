# 17 — Cooling Optimization

Measured thermal and power data for the Latitude 7420 under gaming load, the
configuration applied, and the procedures to reproduce or extend it.

> **Concept and mechanism:** [16 — Thermal & Power Architecture](16-thermal-and-power-architecture.md)
> **Review that corrected this work:** [18 — Adversarial Review Log](18-adversarial-review-log.md)

Captured **2026-08-15**. BIOS 1.50.1, kernel 7.0.0-28-generic, Mint 22.3 Cinnamon, X11.
Workload: **Age of Empires: Definitive Edition** (AppID 1017900, 12.93 GB) via
Proton Experimental + DXVK, Steam native `.deb`.

---

## Priority order

Ranked by measured impact on **this** machine.

| Priority | Action | Why it matters here | Status |
|---|---|---|---|
| 🔴 1 | **Replace the battery** | 23.6% of design health — see [F-01](07-findings-and-risks.md#f-01) | Outstanding |
| 🔴 2 | **Fix battery charge policy** | TLP thresholds silently inert; cell held at 100% SoC | Outstanding — §6 |
| 🟠 3 | **Compositor unredirect** | Removes a full-screen blit per frame; less GPU work **and** less heat | ✅ Applied |
| 🟠 4 | Physical: repaste + fin-stack clean | Beats every software lever combined on a 5-year-old chassis | Outstanding |
| 🟡 5 | `platform_profile` selection | Real but small; **contested** — see §7 | ⚠️ Provisional |
| 🟡 6 | `hwp_dynamic_boost` | Burst response without pinning frequency | ✅ Applied |
| ⚪ 7 | gamemode governor tuning | Measured as a **no-op** on this platform | ✅ Corrected |

---

## 1. Platform profile measurements

### 1.1 Run A — INVALID, retained as a warning

| Profile | Power | Clock | Temp | Busy |
|---|---|---|---|---|
| `balanced` | 18.7 W | 3051 MHz | 60 °C | 100% |
| `performance` | 18.7 W | 3028 MHz | 63 °C | 100% |

**Do not cite these numbers.** The sampling window was 40 s starting ~8 s after
load onset. PL1 averages over **~32 s**, so most of the window sat inside the burst
period. The 18.7 W figure is the **PL2 short-term limit (18.75 W)** being observed,
not a sustained ceiling. See [16 §1.1](16-thermal-and-power-architecture.md).

### 1.2 Run B — internally consistent, still not steady-state

8-thread `sha256sum /dev/zero` burn, 16 samples × 5 s, machine already warm at 66 °C,
a game idling in the background, system load varying 5.4–9.5.

| Profile | Power | Clock | Temp | Fan (end of load) |
|---|---|---|---|---|
| `balanced` | 16.07 W | 2783 MHz | 66 °C | 4302 RPM |
| `quiet` | 14.56 W | 2651 MHz | 66 °C | 4008 RPM |
| `cool` | 14.51 W | 2628 MHz | 66 °C | 4316 RPM |

**Caveats that must travel with this table:**

- `cool` vs `quiet` differ by **0.05 W (0.3%)** — inside sample variance. They are
  **not** distinguishable on power. Only `balanced` separates, and only by ~1.5 W.
- All three reporting **exactly 66 °C** at three different power levels is
  thermodynamically implausible at equilibrium. 66 °C was also the *starting*
  temperature. **Steady state was never reached; there is no valid peak-temp data.**
- Background load was uncontrolled.

### 1.3 Fan-curve probe — confounded

| Profile | Fan RPM | Temp |
|---|---|---|
| `quiet` | 3999 | 64 °C |
| `cool` | 4290 | 65 °C |
| `balanced` | 4295 | 63 °C |
| `performance` | **4703** | 63 °C |

System load varied 5.4 → 9.5 across samples. The ~700 RPM spread and the constant
temperature are *suggestive* that the profile drives the fan curve, but this is not
a controlled result. `performance` (= BIOS `UltraPerformance`) is the max-airflow
mode and was **never tested head-to-head at steady state**.

---

## 2. Gameplay measurement — AoE: DE

turbostat, 45 s, columns parsed **by name**.

| Metric | Value |
|---|---|
| CPU cores | **5.04 W** |
| GPU (gfx) | **3.41 W** (peak 3.68) |
| Uncore / rest | 3.34 W |
| **Package total** | **11.79 W** (peak 12.11) |
| CPU busy | 17.9% @ 2305 MHz |
| GPU clock | requested 1267–1278 MHz, `gt_act_freq` 750 MHz |
| Package temp | 55 °C |
| Top process | `AoEDE_s.exe` 66.7% CPU, 17.8% MEM |

**Against a ~28–30 W sustained ceiling, the title uses roughly 40% of budget.**
Neither CPU nor GPU is close to saturation.

> **Unresolved.** There is **no FPS measurement** for this run — MangoHud was not
> loaded. The inference that the title is vsync-locked at 60 Hz is *unverified*,
> and the `gt_act_freq` 750 MHz reading is **not** valid evidence of GPU idleness:
> that file is an instantaneous RPSTAT snapshot that reads **0** in RC6, so a
> consistent 750 MHz means the GT was awake and running *below* the requested
> clock. See [18](18-adversarial-review-log.md) and §8.

---

## 3. Component temperatures

| Component | Idle | Under load | Limit |
|---|---|---|---|
| CPU package | 41–47 °C | 60–66 °C | 100 °C (trip ≈ 98 °C) |
| NVMe (KIOXIA BG4) | 33–44 °C | — | 82.85 °C (crit 86.85 °C) |
| Skin (`TSKN`) | 36–47 °C | 51 °C | 60 °C trip |
| Wi-Fi (AX201) | 54–57 °C | — | — |
| Fan | **~4300 RPM under `cool`, never stops** | 4300–4700 RPM | 4800 RPM max |

Throttle counters: `core_throttle_count = 0`, `package_throttle_count = 0`.
**Nothing on this machine has ever thermally throttled.**

---

## 4. Applied configuration

### 4.1 Compositor — the highest-value change

```bash
gsettings set org.cinnamon.muffin unredirect-fullscreen-windows true
```

Default is `false`, which composites fullscreen windows every frame. Removing that
blit reduces GPU work, latency, **and** heat.

### 4.2 `hwp_dynamic_boost`

```bash
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost
```

Was `0`. Under `intel_pstate` active + HWP + `powersave`, this grants burst
responsiveness on task wakeup **without** pinning frequency the way the
`performance` governor does — better targeted than the governor debate, and it
leaves steady-state budget available to the iGPU.

> Not persistent across reboot. Add to `/etc/tmpfiles.d/` or a systemd unit if wanted.

### 4.3 gamemode

`/etc/gamemode.ini`:

```ini
[general]
renice=10
ioprio=1
softrealtime=auto
inhibit_screensaver=1
desiredgov=powersave
```

Notes that matter:

- `desiredgov=powersave` is a **no-op** — the governor is already `powersave` (set
  by TLP). It is retained only to prevent gamemode's built-in default of
  `performance` from applying, which *would* bias the shared budget toward the CPU.
  The knob that actually steers boost is **EPP** (`balance_performance`), which
  gamemode never touches.
- `defaultgov` is deliberately **unset**. It is what gamemode *restores on exit*;
  pinning it would stomp any future governor change every time a game closes.
- `inhibit_screensaver=1` prevents cinnamon-screensaver locking mid-game.
- `apply_gpu_optimisations` unset — `gt_max_freq_mhz == gt_RP0_freq_mhz == 1300`,
  so there is nothing to raise.
- **`renice` requires membership of the `gamemode` group and a re-login.**
  `/etc/security/limits.d/10-gamemode.conf` grants `@gamemode - nice -10`; a live
  session shows `ulimit -e` = 0 until re-login, where it becomes 30.

### 4.4 Steam launch options

```
MANGOHUD=1 gamemoderun %command%
```

**Not** `gamemoderun mangohud %command%`. The `mangohud` wrapper preloads
`/usr/$LIB/mangohud/libMangoHud.so`; `$LIB` expands to `i386-linux-gnu` for the
32-bit half of the Steam chain, and **`mangohud:i386` does not exist in Ubuntu
noble** — producing preload errors on every 32-bit process. Pressure-vessel imports
host Vulkan implicit layers by default, so `MANGOHUD=1` alone activates the overlay
cleanly inside the container.

### 4.5 Packages required for the overlay to report anything

```bash
sudo apt install intel-gpu-tools libgamemodeauto0:i386
```

MangoHud obtains Intel GPU load/clock/power by **spawning `intel_gpu_top`**. Without
`intel-gpu-tools` the `gpu_stats`, `gpu_core_clock` and `gpu_power` fields are blank.

> `throttling_status` in `MangoHud.conf` is **AMD-only** and is dead weight on Intel.
> `perf_event_paranoid` is `4` on this system; `intel_gpu_top` needs `≤2` or root.

### 4.6 Reverted — `MESA_SHADER_CACHE_MAX_SIZE`

Set to `10G` in `/etc/environment`, then **reverted**. It was inert three ways:
not present in the live Steam environment (pam_env applies at login), overridden by
`steamclient.so` which sets the variable itself, and irrelevant in foz/single-file
cache mode where size eviction does not apply. The actual shader working set is
**8.7 MB** — of the 668 MB shader cache directory, **659 MB is
`transcoded_video.foz`** (video transcode, not shaders) and `DXVK_state_cache`
contains **zero files** (DXVK 2.x removed it).

---

## 5. Reproducible measurement procedure

```bash
# 1. Quiesce. Steam idles at ~34% CPU with ~16% more across three helpers.
# 2. Soak 5 minutes per profile, sample only the final 2 minutes.
sudo turbostat --quiet --interval 5 \
  --show PkgWatt,CorWatt,GFXWatt,GFX%rc6,GFX%C0,GFXMHz,Busy%,Bzy_MHz,PkgTmp

# 3. Log fan, NVMe and skin temperature alongside every power sample.
cat /sys/class/hwmon/hwmon*/fan1_input
sensors | grep -E 'Composite|Package id 0'

# 4. Settle GPU saturation with the right file.
grep . /sys/class/drm/card1/gt/gt0/throttle_reason_*

# 5. Per-process engine utilisation (no extra packages).
pid=$(pgrep -f AoEDE_s.exe); grep -l drm-engine-render /proc/$pid/fdinfo/*

# 6. i915 PMU time-averages (perf is installed; needs sudo at paranoid=4).
sudo perf stat -a -e i915/rcs0-busy/,i915/rc6-residency/,\
i915/actual-frequency/,i915/requested-frequency/ -I 1000
```

Parse turbostat **by column name** — column order varies with flags.

---

## 6. Battery charge policy — outstanding

The battery is at **23.6% of design capacity** (`charge_full` 963000 µAh vs
`charge_full_design` 4072000 µAh) and is held at **100% SoC** on AC.

**The TLP thresholds in `/etc/tlp.d/01-latitude-7420.conf` are not being applied.**

```
config says:  START_CHARGE_THRESH_BAT0=95   STOP_CHARGE_THRESH_BAT0=100
sysfs says:   charge_control_start_threshold=50   end_threshold=100
```

Root cause: `CustomChargeStart` / `CustomChargeStop` carry
`dell_modifier = [ReadOnlyIfNot:PrimaryBattChargeCfg=Custom]`, and
`PrimaryBattChargeCfg` is `Adaptive`. The custom values are read-only in that mode.

Fix (BIOS tokens, via `dell-wmi-sysman`):

```
PrimaryBattChargeCfg = Custom
CustomChargeStart    = 55      # allowed range 50–95
CustomChargeStop     = 70      # allowed range 55–100
```

Or `PrimAcUse` for a permanently-docked machine. **This reduces unplugged runtime**
and is an owner decision. It protects the *replacement* battery as much as the
current one — see [05 §Set charge thresholds](05-post-install-optimization.md).

---

## 7. `platform_profile` — provisional, contested

Currently **`cool`** (BIOS token `ThermalManagement=Cool`, persistent).

The two reviews disagree, and **neither position rests on valid steady-state data**:

| Position | Argument |
|---|---|
| `UltraPerformance` | Max airflow. Nothing throttles, 32 °C headroom, and airflow benefits NVMe/VRM/battery — parts with no headroom telemetry. Extra heat is ~1.5–4 W the chassis can absorb. |
| `balanced` | `cool` is the most restrictive profile; `balanced` is the sane gaming default and matches the machine's own documentation. |
| `cool` (current) | Demonstrably lower NVMe temperature under forced airflow. But the fan **never stops**, which is continuous bearing wear and faster dust ingestion. |

**This must be settled by the controlled A/B in §5, not by argument.**
See `scripts/post-reboot-gaming-baseline.sh`.

---

## 8. Open questions

1. **No FPS baseline exists.** Everything about GPU saturation is inference.
2. **Is the GPU power-clamped during gameplay?** `throttle_reason_pl1|pl2|pl4|vr_tdc`
   was never read under load. If any reads `1`, the "not power-limited" conclusion fails.
3. **`cool` vs `UltraPerformance` at steady state** — unmeasured (§7).
4. **Does the systemd unit `platform-profile-cool.service` serve any purpose?**
   The BIOS token appears self-persistent; one reboot settles it. Its
   `WantedBy=suspend.target` entries are **wrong** — those targets activate *before*
   sleep, not after resume.
5. **Does `renice`/`ioprio` reach the game?** gamemode applies them to the process
   that *registered*, which is a host-side wrapper in the reaper/pressure-vessel
   chain — probably not `AoEDE_s.exe` inside the container.
