# 18 — Adversarial Review Log

Two independent adversarial reviews of the 2026-08-15 cooling and gaming-stack
work, their findings, **which claims survived verification**, and the alternate
recommendations that were considered and not taken.

> Both reviewers operated **read-only**. No system state was changed by either.
> Every claim below was independently re-verified against the live machine before
> being accepted; results are recorded in the **Verified?** columns.

---

## Method

Two reviewers were run in parallel with deliberately narrow, opposing briefs, each
given the raw measurements and explicitly instructed to **attack** the conclusions
rather than confirm them:

| Reviewer | Brief |
|---|---|
| **A — Thermal / longevity** | Cooling decisions, profile choice, power-cap model, missed longevity levers |
| **B — Gaming / configuration** | Proton/Mesa/DXVK stack, gamemode, measurement metrics, config correctness |

Each was given the author's own stated uncertainties as attack surface. This
mattered: **the two most valuable findings in this document came from areas the
author flagged as unsure, not from areas assumed correct.**

---

## Headline outcome

The original work contained **one framing error that invalidated much of the
reasoning built on it**, and **one high-value change that was never considered**.

1. **The "18.7 W shared budget" model was wrong.** 18.75 W is the *MMIO short-term*
   limit; sustained is ~28–30 W. Every downstream argument that treated 18.7 W as a
   hard sustained ceiling was reasoning from the wrong constraint.
2. **The compositor was never checked.** `unredirect-fullscreen-windows=false`
   composites fullscreen games every frame — almost certainly the real cause of the
   60 fps behaviour attributed to game vsync, and free to fix.

---

## Reviewer A — Thermal & longevity

### A.1 Claims that were CONFIRMED

| # | Claim | Verified? | Evidence |
|---|---|---|---|
| A1 | Battery at **23.6%** of design capacity | ✅ | `charge_full` 963000 / `charge_full_design` 4072000 µAh |
| A2 | TLP charge thresholds **not applied** | ✅ | config 95/100, sysfs reports **50/100** |
| A3 | Root cause: `PrimaryBattChargeCfg=Adaptive` makes custom values read-only | ✅ | `dell_modifier=[ReadOnlyIfNot:PrimaryBattChargeCfg=Custom]` |
| A4 | Fan **never stops** under `cool` | ✅ | 4325 RPM at 47 °C, load 1.57 |
| A5 | BIOS token is self-persistent → systemd unit likely redundant | ✅ | `ThermalManagement/current_value` = `Cool` (root-readable) |
| A6 | `UltraPerformance` exists and was never tested | ✅ | `possible_values=Optimized;Cool;Quiet;UltraPerformance;` |
| A7 | `cool` vs `quiet` power delta is **noise** (0.05 W) | ✅ | Author's own Run B data |
| A8 | 66 °C convergence is an artifact, not a finding | ✅ | Three power levels, identical temp, = starting temp |
| A9 | Never thermally throttles | ✅ | `core_throttle_count=0`, `package_throttle_count=0` |
| A10 | `WantedBy=suspend.target` is wrong for post-resume | ✅ | Those targets activate *before* sleep |
| A11 | `desiredgov=powersave` is a no-op | ✅ | Governor already `powersave` on all 8 CPUs |
| A12 | `thermald` running in fallback (no adaptive policy) | ✅ | `current_uuid` empty; "Unable to find a zone for TSSD" |

### A.2 Claims that were REFUTED

| # | Claim | Verdict |
|---|---|---|
| A13 | "Platform PL1 ceiling is **15 W** (`power_limit_0_max_uw = 15000000`)" | ❌ **Wrong.** That file does not exist. `constraint_0_max_power_uw` = **28000000** (28 W) — the i5-1145G7's cTDP-up. The conclusion that 18.7 W was "arithmetically impossible" does not hold. |

> The reviewer's *methodological* criticism of the same measurement was
> nevertheless correct for a different reason — PL1 tau is ~32 s, so the sampling
> window mixed burst into sustained. **Right conclusion, wrong number.** This is
> why every agent claim in this document was re-verified rather than accepted.

### A.3 Alternate recommendations — considered, NOT taken

| Recommendation | Why not taken |
|---|---|
| **Switch `cool` → `UltraPerformance`** | Defensible: max airflow, nothing throttles, benefits NVMe/VRM/battery. **Deferred** — no valid steady-state data exists either way. To be settled by controlled A/B, not argument. See [17 §7](17-cooling-optimization.md). |
| **Raise `tcc_offset_degree_celsius`** (currently 2, writable) to lower the effective thermal trip | Rejected as unnecessary. The trip is ~98 °C and the machine peaks at 66 °C; a lower trip has nothing to act on. No cost, but no benefit either. |
| **Undervolting** | **Rejected outright.** Tiger Lake's voltage-offset mailbox was removed post-Plundervolt (CVE-2019-11157). Even where it works it trades silent instability for a few watts — a direct contradiction of a longevity goal. |
| **Cap `gt_max_freq_mhz`** to reduce GPU heat | Rejected. Evidence does not support it: package was 11.79 W against a ~28 W ceiling, so the GPU was not power-starved. Capping costs frames without cutting heat actually being generated. |
| **Configure NVMe HCTM / TMT1-TMT2 thermal thresholds** | **Deferred, worth doing.** `nvme-cli` is not installed so `get-feature -f 0x10` was unreadable. Drive is at 33–44 °C against an 82.85 °C limit, so not urgent — but it is the second-most-degradable component. |
| **Interfaces that will not help** | `i8kutils` (same SMM path — `pwm1_enable` rejection is the BIOS refusing), `dell-smm-hwmon` module params `force`/`ignore_dmi`/`restricted`, `libsmbios-bin` (**no install candidate on noble**), `smbios-thermal-ctl` (would set the same token already exposed). Documented so the search is not repeated. |

### A.4 Reviewer A's strongest point

> *"The profile decision is a rounding error dressed up as engineering… the battery
> at 23.6% of design capacity being held at 100% SoC is where the actual longevity
> damage is happening."*

Accepted. Also note the repository **already** ranked battery replacement as
priority 1 in [05](05-post-install-optimization.md) and [F-01](07-findings-and-risks.md#f-01)
— the session had drifted from its own documented priorities.

---

## Reviewer B — Gaming stack & configuration

### B.1 Claims that were CONFIRMED

| # | Claim | Verified? | Evidence |
|---|---|---|---|
| B1 | `unredirect-fullscreen-windows = false` — games composited every frame | ✅ | `gsettings get` returned `false` |
| B2 | Real cap is **MMIO** RAPL, not MSR | ✅ | `intel-rapl-mmio:0`: long 30 W (max 28 W), short **18.75 W** |
| B3 | `MESA_SHADER_CACHE_MAX_SIZE` absent from live Steam env | ✅ | 0 MESA vars in `/proc/22100/environ` |
| B4 | Steam sets the variable itself, overriding `/etc/environment` | ✅ | `steamclient.so` strings contain `MESA_SHADER_CACHE_MAX_SIZE`, `MESA_DISK_CACHE_SINGLE_FILE` |
| B5 | Shader cache is **98% video**, not shaders | ✅ | 659 MB `transcoded_video.foz` vs 8.7 MB `mesa_shader_cache_sf` |
| B6 | `DXVK_state_cache` is **empty** | ✅ | 0 files; DXVK 2.x removed it |
| B7 | MangoHud needs `intel_gpu_top`, not installed | ✅ | `intel-gpu-tools` Installed: (none) |
| B8 | `hwp_dynamic_boost` = 0, a missed knob | ✅ | Confirmed; now set to 1 |
| B9 | `throttle_reason_*` files exist and were never read | ✅ | 9 files under `/sys/class/drm/card1/gt/gt0/` |
| B10 | `libgamemodeauto0:i386` missing but available | ✅ | Candidate 1.8.1-2build1; now installed |
| B11 | `gt_act_freq_mhz` reads **0** in RC6 → 750 MHz means *awake and clamped*, not idle | ✅ | Idle baseline `GFX%rc6=94.4, GFXAMHz=0` |
| B12 | `mangohud` wrapper breaks on 32-bit (`$LIB` → `i386-linux-gnu`) | ✅ | `mangohud:i386` does not exist in noble |
| B13 | `throttling_status` in MangoHud.conf is AMD-only | ✅ | Binary vendor strings are `amdgpu`/`Radeon` only |

### B.2 Claims requiring qualification

| # | Claim | Qualification |
|---|---|---|
| B14 | "Vulkan 1.4" is wrong | Half right. Driver `apiVersion` **is** 1.4.318; the host **loader** is 1.3.275. Irrelevant for Proton (container ships its own loader), but the host-level claim was imprecise. |
| B15 | `renice`/`ioprio` will not reach the game | Plausible and unverified. gamemode applies to the *registering* process — a host-side wrapper in the reaper/pressure-vessel chain, not `AoEDE_s.exe`. Testable after re-login. |

### B.3 Alternate recommendations — considered, NOT taken

| Recommendation | Why not taken |
|---|---|
| **Lower `perf_event_paranoid` from 4 to 2** | Required for `intel_gpu_top` (and therefore MangoHud's GPU fields) as non-root. **Deferred to owner** — it loosens unprivileged perf access system-wide, a genuine security tradeoff on a machine whose docs otherwise take hardening seriously. |
| **Set `platform_profile=balanced`** | Reviewer B's view; collides directly with Reviewer A's `UltraPerformance`. Both deferred to the controlled A/B. |
| **`fps_limit=58` + `fps_limit_method=late`** | **Strong candidate, deferred.** A cap slightly under vsync removes GPU work with no visible cost on a 60 Hz panel — ideal for the heat/longevity goal. Must not be set to exactly 60 against 60 Hz vsync (beating). Requires a baseline first. |
| **`workqueue.power_efficient=0`** on kernel cmdline | Currently `Y` via TLP; adds latency to deferred work, a micro-stutter candidate. Not taken — speculative, requires a kernel cmdline change and a reboot to test. |
| **`MESA_SHADER_CACHE_MAX_SIZE=2G`** as a compromise for native GL/Vulkan apps | Not taken. Still 100× the 17 MB combined working set; removing the variable entirely is the honest answer. |
| **VKD3D / mesa_glthread / DXVK async** | **Category errors, correctly dismissed by the reviewer.** AoE:DE is pure D3D11 (no D3D12 entry points), so VKD3D is irrelevant; `mesa_glthread` is OpenGL-only and the path is D3D11→DXVK→Vulkan; DXVK "async" never existed upstream and GPL is automatic where supported. Recorded so they are not revisited. |

### B.4 Reviewer B's strongest point

> *"The biggest problem isn't in any file you edited — it's the compositor."*

Accepted and applied immediately. It is the only change identified in the entire
session that improves performance **and** reduces heat **and** costs nothing.

---

## Corrections applied as a result

| Change | Status |
|---|---|
| `unredirect-fullscreen-windows = true` | ✅ Applied |
| `MESA_SHADER_CACHE_MAX_SIZE` reverted | ✅ Applied |
| `hwp_dynamic_boost = 1` | ✅ Applied |
| `intel-gpu-tools`, `libgamemodeauto0:i386` installed | ✅ Applied |
| `gamemode.ini`: false prose corrected, `defaultgov` removed, power figures fixed | ✅ Applied |
| Launch options → `MANGOHUD=1 gamemoderun %command%` | ⏳ Owner action |
| Battery charge policy | ⏳ Owner decision — [17 §6](17-cooling-optimization.md) |
| `platform_profile` final selection | ⏳ Pending controlled A/B |
| `platform-profile-cool.service` — keep, fix, or delete | ⏳ Pending one reboot |

---

## Lessons recorded

1. **Verify the agent, not just the work.** Reviewer A's central numeric claim
   (15 W) was wrong while its methodological criticism was right. Accepting either
   wholesale would have been an error.
2. **Name your uncertainties in the brief.** Both reviewers' best findings came
   from areas explicitly flagged as unsure.
3. **Check the layer above before tuning the layer below.** A compositor setting
   outweighed every power-subsystem adjustment made in the session.
4. **Measure the constraint that binds.** Reading MSR RAPL instead of MMIO RAPL
   produced a wrong model that survived several hours of reasoning.
5. **A repository's own priority list is evidence.** Battery replacement was
   already priority 1 here; the session rediscovered it the hard way.
