# 04 — Blockers & Prerequisites

> **Read this before anything else.**
> Two conditions currently make it **unsafe** to repartition this machine. Both must
> be cleared from **inside Windows**, then re-verified from the Mint live USB.

---

## Blocker summary

| # | Condition | Evidence | Cleared by |
|---|---|---|---|
| 1 | Hibernation image present | `hiberfil.sys`, 6.3 GB, written 2026-08-14 12:07 | `powercfg /h off` + disable Fast Startup + full shutdown |
| 2 | NTFS filesystem inconsistent | 8,851 cluster accounting mismatches in `$Bitmap` | `chkdsk C: /f` + reboot twice |

**Order matters: clear Blocker 1 first.** While a hibernation image exists, Windows
resumes rather than boots, and `chkdsk` cannot fully repair the volume.

---

## Prerequisite 0 — Back up first ⚠️

**This is not optional and it is not a formality.**

The Windows partition contains ~55 GB including a user profile at `/Users/user`
(5.5 GB, last modified 2026-07-16). Repartitioning a disk always carries risk, and
this disk starts from a **known-corrupt filesystem**.

Before any of the steps below:

1. Copy `C:\Users\user` to external media or cloud storage.
2. Note the Windows product activation state (Settings → System → Activation).
   Digital licences are tied to the hardware and survive repartitioning, but record
   it anyway.
3. Confirm you have a way to reinstall Windows if the worst happens
   (Dell provides recovery images by service tag at dell.com/support).
4. Consider a full image backup (Macrium Reflect, Clonezilla) if the data is
   irreplaceable.

You can copy the data out **right now from the live session** — the Windows partition
mounts read-only without any risk:

```bash
sudo mkdir -p /mnt/win
sudo mount -o ro /dev/nvme0n1p3 /mnt/win
# copy /mnt/win/Users/user to external media
sudo umount /mnt/win
```

> Read-only mounting is safe even in the current corrupt/hibernated state.
> **Never mount it read-write in this condition.**

---

## Blocker 1 — Remove the hibernation image

### Why

`hiberfil.sys` (6.3 GB) means Windows saved a RAM image to disk instead of shutting
down. Windows 11's **Fast Startup** does this on every "Shut down" by default. On
resume, Windows restores its cached filesystem metadata and assumes the on-disk
layout is byte-identical to what it left.

**Shrink the partition while that image exists and Windows resumes into a filesystem
that no longer matches its own cache. The corruption that follows is usually
unrecoverable.**

### Fix

Boot into Windows, then open **Command Prompt or PowerShell as Administrator**:

```cmd
powercfg /h off
```

This disables hibernation entirely and deletes `hiberfil.sys`, reclaiming 6.3 GB.
It also disables Fast Startup as a side effect, since Fast Startup depends on it.

Then confirm Fast Startup is off in the GUI as well:

> Control Panel → Hardware and Sound → Power Options →
> **Choose what the power buttons do** → *Change settings that are currently
> unavailable* → untick **Turn on fast startup (recommended)** → Save changes

### Optionally also remove the pagefile

Not required, but it frees another 2.9 GB and lets Windows shrink further:

> System Properties → Advanced → Performance **Settings** → Advanced →
> Virtual memory **Change** → untick *Automatically manage* → **No paging file** →
> Set → OK → reboot

**Re-enable the pagefile after the resize is complete.** Windows genuinely needs it.

### Then shut down properly

Do **not** use "Shut down" if you skipped the GUI step — with Fast Startup still
enabled it would hibernate again. Either:

- **Restart** (a restart is always a true full boot, even with Fast Startup on), or
- Hold **Shift** while clicking Shut down, or
- Run `shutdown /s /t 0` from an admin prompt.

---

## Blocker 2 — Repair the NTFS filesystem

### Why

`ntfsresize` found **8,851 cluster accounting mismatches** — the `$Bitmap` allocation
map disagrees with the MFT about which clusters are in use. Resizing relocates
clusters based on that map. If the map is wrong, the wrong data gets moved, or real
data does not get moved out of the truncated region. Either way: **silent data loss**.

`ntfsresize` refuses to run, and GParted (which wraps `ntfsresize`) will refuse too.
This is protective, correct behaviour — not a bug to work around.

### Fix

With hibernation already off (Blocker 1), boot Windows and run as **Administrator**:

```cmd
chkdsk C: /f
```

It will report that the volume is in use and ask to schedule for the next restart.
Answer **Y**, then restart.

```
Would you like to schedule this volume to be checked
the next time the system restarts? (Y/N) Y
```

### Reboot **twice** — this matters

`ntfsresize` explicitly instructs "reboot it TWICE". The reason:

- **First boot** — `chkdsk` runs during startup and repairs `$Bitmap`.
- **Second boot** — Windows completes post-repair journal replay and commits a clean
  state to disk. Without it, the volume can still carry a dirty flag that `ntfsresize`
  will reject.

Let both boots reach the desktop fully before shutting down.

### If `chkdsk` finds serious damage

If it reports bad sectors or unrecoverable files, **stop**. Re-check SMART from the
live USB (`sudo smartctl -a /dev/nvme0n1`). Current SMART shows **0 media and data
integrity errors**, so genuine bad sectors are unlikely — but if `chkdsk` disagrees
with SMART, treat the drive as suspect and back up before anything else.

---

## Re-verification — from the Mint live USB

After both blockers are cleared and Windows has been fully shut down, boot the Mint
live USB again and confirm. **All three checks must pass.**

### Check 1 — hibernation file is gone

```bash
sudo mkdir -p /mnt/win
sudo mount -o ro /dev/nvme0n1p3 /mnt/win
ls -la /mnt/win/hiberfil.sys
# EXPECTED: "No such file or directory"
sudo umount /mnt/win
```

### Check 2 — filesystem is consistent

```bash
sudo ntfsresize --info --force /dev/nvme0n1p3
```

**Expected (pass):**
```
Current volume size: 511150387712 bytes (511151 MB)
Checking filesystem consistency ...
100.00 percent completed
Accounting clusters ...
Space in use       : 55000 MB (10.8%)
Collecting resizing constraints ...
You might resize at 49xxxxxxxxx bytes or 49xxx MB (freeing xxxxx MB).
```

The key line is **`You might resize at …`** — that only appears when the check
passes. If you still see `Cluster accounting failed` or
`ERROR: NTFS is inconsistent`, **the repair did not take**. Repeat Blocker 2. Do not
proceed.

### Check 3 — volume is not flagged dirty

```bash
sudo ntfsfix -n /dev/nvme0n1p3
```

`-n` is **no-action** mode — it reports without writing. Expect
`Processing of $MFT and $MFTMirr completed successfully` and no dirty-flag warning.

> ⚠️ Do **not** run `ntfsfix` without `-n` as a substitute for `chkdsk`.
> `ntfsfix` only clears the dirty flag and fixes trivial issues — it does **not**
> repair `$Bitmap` accounting. Using it to silence the warning would let a resize
> proceed on a still-corrupt filesystem. That is the single most dangerous mistake
> available at this stage.

---

## Prerequisite checklist

Do not open GParted until every box is ticked.

- [ ] Windows user data backed up to external media
- [ ] Windows activation state recorded
- [ ] `powercfg /h off` executed as Administrator
- [ ] Fast Startup unticked in Power Options
- [ ] (optional) Pagefile disabled for the resize
- [ ] `chkdsk C: /f` scheduled and completed
- [ ] Windows rebooted **twice**, reaching the desktop both times
- [ ] Windows shut down fully (Shift+Shutdown, or `shutdown /s /t 0`)
- [ ] **Check 1** — `hiberfil.sys` absent ✅
- [ ] **Check 2** — `ntfsresize --info` reports `You might resize at …` ✅
- [ ] **Check 3** — `ntfsfix -n` reports clean ✅
- [ ] Laptop connected to **AC power** (see below)
- [ ] BIOS settings reviewed → [06 — BIOS/UEFI Configuration](06-bios-uefi-configuration.md)

---

## ⚠️ Special warning for this machine: power stability

**The battery is at 23.65% of design health** (14.6 Wh of 61.9 Wh) and the SSD has
recorded **26 unsafe shutdowns**. Those two facts are almost certainly related — a
battery this degraded can collapse under load even when the gauge reads a healthy
percentage.

**A power loss during a partition resize is one of the few ways to lose the entire
disk irrecoverably.** The partition table, the NTFS `$MFT`, and the relocated cluster
data are all in flux simultaneously.

Therefore:

1. **Run the entire operation on AC power.** Verify before starting:
   ```bash
   cat /sys/class/power_supply/AC*/online   # must be 1
   ```
2. Confirm the adapter is the correct **65 W** Dell USB-C unit. The adapter observed
   during this audit negotiated only **15 V / 3 A = 45 W**, which is under-spec for
   this platform.
3. Use a mains socket, not a dock or a shared power strip that might be knocked.
4. Do not move the laptop while the resize is running.
5. Budget uninterrupted time — a ~400 GB shrink can take a while, and **it must not
   be interrupted**.

Replacing the battery before doing any of this would be the genuinely prudent choice.

---

## Next

Once every box above is ticked → [03 — Partitioning Plan](03-partitioning-plan.md).
