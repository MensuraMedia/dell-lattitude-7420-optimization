# 12 — Build Log: First Boot Through Post-Boot Tuning

Record of the session that took the machine from "booted through LUKS for the
first time, nothing else done" to a fully patched system with post-boot tuning
staged. Written to complement `docs/10-change-log.md`, which stops at installer
exit.

Date: 2026-08-14. Starting state: first successful boot, kernel 6.14.0-37,
zero post-boot steps taken.

---

## Summary of what was found

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | Timeshift configured to snapshot **to `/boot`** | Critical | Fixed |
| 2 | System 7 months behind: 406 pending, 290 security | High | Fixed |
| 3 | `intel-microcode` cannot fix GDS on this hardware | High | Won't fix — see below |
| 4 | `post-boot-setup.sh` had never been run | High | Staged |
| 5 | `casper` live-ISO remnant + failed unit | Low | Fixed |
| 6 | Single LUKS keyslot | High | Outstanding |
| 7 | `ufw` installed and inactive — no host firewall | Medium | Outstanding |
| 8 | `GRUB_TIMEOUT=0`, no recovery menu access | Low | Fixed |
| 9 | No real fallback kernel (`initrd.img.old` self-referential) | Low | Fixed |

---

## 1. Timeshift targeting `/boot` (critical)

`/etc/timeshift/timeshift.json` had `backup_device_uuid` set to the UUID of
`/dev/nvme0n1p2` — the 2 GiB `/boot` partition — with `schedule_daily=true` and
`count_daily=5`, against a root filesystem of 9.1 GiB.

The first scheduled run would have filled `/boot` to 100%. On a LUKS root that
means `update-initramfs` silently truncates the initramfs and the machine stops
booting. A new kernel was queued behind it, which would have triggered exactly
that rebuild.

Created by the Timeshift GUI wizard, not by any script here: the
`/boot/timeshift` scaffolding was timestamped after `/etc/cron.d/timeshift-hourly`
was installed.

Fixed by repointing to `lv_home`, reducing retention to 3, and removing the
empty scaffolding from `/boot`.

**Repo implication.** `post-boot-setup.sh` step 15 only checks that the package
is installed and emits an advisory note. It cannot detect a bad target. Consider
promoting this to an assertion that compares `backup_device_uuid` against the
UUIDs of `/` and `/boot` and fails loudly.

---

## 2. Update backlog

406 packages upgraded, 12 newly installed, 290 carrying security updates. The
ISO was built in January and the machine first booted in August.

This also brought the HWE kernel from 6.14.0-37 to 7.0.0-28. `/boot` went from
112 MiB to 228 MiB (12% of 2 GiB) — the 2 GiB sizing is correct, because the
encrypted-root initramfs is ~85 MiB per kernel.

---

## 3. GDS / Downfall is unreachable via apt

`docs/11` step 1 says installing `intel-microcode` mitigates GDS. On this
machine it does not, and cannot.

```
CPU signature            : 0x000806C1  (family 6, model 140, stepping 1)
Dell BIOS 1.50.1 loads   : revision 0xBE
intel-microcode 20250812 : revision 0xBC   (older — kernel correctly skips it)
intel-microcode 20260210 : revision 0xBE   (identical to BIOS)
/sys/.../gather_data_sampling : Vulnerable
```

The newest Ubuntu microcode package ships exactly what the firmware already
loads. There is no newer revision for apt to deliver, and the kernel command
line contains no mitigation opt-out. Either the mitigation is not enabled at
0xBE on this stepping, or it is disabled and locked by Dell firmware.

**Repo implication.** Two changes are warranted:

1. `docs/11` Phase G lists "**GDS** — not `Vulnerable`" as an acceptance
   criterion. On this hardware that criterion cannot be met by any documented
   step, so every validation run reports an unfixable failure. It should be
   amended to "not `Vulnerable`, **or** documented as firmware-limited".
2. `post-boot-setup.sh` Phase A step 1 guards with `dpkg -s intel-microcode`,
   which tests *presence*, not *version*. The package ships on the Mint ISO, so
   the check always short-circuits and the step never upgrades anything. It
   should compare installed vs candidate version instead.

The only remaining avenue is a BIOS update (Phase E step 11).

---

## 4. Post-boot script had never run

Confirmed by the absence of every artifact `post-boot-setup.sh` creates:
`/etc/fstab.bak.*`, `/etc/default/grub.bak.*`,
`/etc/sysctl.d/99-mint-tuning.conf`, `/etc/tlp.d/`,
`/etc/initramfs-tools/conf.d/resume`, `/etc/default/zramswap`, and the UPower
`CriticalPowerAction` line.

By contrast `post-install-crypttab.sh` (Phase 0) demonstrably *did* run — all
seven of its assertions verify independently, and the LUKS header backup it
creates is timestamped during the install session.

---

## 5. `casper` remnant

`casper` 1.498 was still installed on a permanent install, causing the only
failed unit (`casper-md5check.service`). Purged.

---

## 6. Single LUKS keyslot

`luksDump` shows slot 0 only. One forgotten passphrase is unrecoverable data
loss. `docs/11` step 2 already recommends `luksAddKey`; it is worth promoting
from "consider" to a required step, since the whole encrypted design has a
single point of failure until it is done.

Note the ordering trap: the header backup is invalidated every time keyslots
change. It must be re-taken after `luksAddKey` **and** again after TPM
enrolment, or a restore would silently revoke the newer keys.

---

## 7. `ufw` — unit active, firewall inactive

```
systemctl is-active ufw  -> active
ufw status               -> Status: inactive
```

The systemd unit being active says nothing about whether packets are filtered.
Mint ships `ufw` installed but with no ruleset enabled, so the machine has no
host firewall. Any check that uses `systemctl is-active ufw` as a proxy for
"firewall on" is wrong — only `ufw status` is authoritative.

Not currently covered anywhere in `docs/11`. Worth a Phase F step for a laptop
that roams untrusted networks.

---

## 8–9. Boot resilience

`GRUB_TIMEOUT=0` with `GRUB_TIMEOUT_STYLE=hidden` meant no way to reach the
menu or a recovery entry — on a single-kernel encrypted box. Set to `3` with
the menu visible.

Before the upgrade, `/boot/initrd.img.old` symlinked to the *same* file as
`/boot/initrd.img`, so there was no fallback at all. With two kernels installed
the `.old` links now resolve to 6.14.0-37 and GRUB lists both kernels plus
recovery entries.

---

## Capacity assessment

No partition required resizing. Post-upgrade:

| Mount | Size | Used | Verdict |
|---|---|---|---|
| `/` | 118 G | 12 G (11%) | ample |
| `/boot` | 2.0 G | 228 M (13%) | correctly sized for ~85 MiB initramfs |
| `/boot/efi` | 1022 M | 6.2 M (1%) | oversized, harmless, not worth repartitioning |
| `/home` | 275 G | 11 G (4%) | ample (8.8 G is the Timeshift snapshot) |
| VG free | — | 53.92 GiB | intentional reserve, left unallocated |

Inode usage peaks at 7%. `/boot` costs ~111 MiB per kernel set, so even 8
retained kernels would reach only ~44%. Growth, if ever needed, is an online
`lvextend -r` against the reserve — no repartitioning.

---

## Tooling added

- `scripts/handoff.sh` — read-only state verification. Prints acceptance
  criteria as PASS/FAIL, all 18 runbook steps as DONE/PENDING, capacity,
  security posture, and the ordered outstanding actions. Safe to re-run.
- `scripts/preflight-and-upgrade.sh` — the pre-reboot stage described above.
- `scripts/post-boot-tuning.sh` — wraps `post-boot-setup.sh` with
  preconditions and supplementary checks it does not perform.

### A bug class worth knowing about

`handoff.sh` originally used `set -o pipefail` alongside probes shaped like
`producer | grep -q pattern`. `grep -q` exits on first match, the producer takes
SIGPIPE, and under `pipefail` the pipeline returns non-zero — turning a
*successful* match into a false negative. It reported the Phase 0 crypttab
repair as PENDING when it had in fact succeeded.

This bites hardest on large producers such as `lsinitramfs`, which emits
thousands of lines. Any status script that mixes `pipefail` with `grep -q` is
suspect. Fixed by dropping `pipefail` and using `grep -c` with a count
comparison where the producer is large.
