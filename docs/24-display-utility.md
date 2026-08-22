# 24 — display-utility

A small tool that supplies the display mode Cinnamon does not offer: **use this
monitor only**. Command line and applications menu, with a revert guard and a
layout that survives login.

> **Why the layout kept resetting:** [21 §7](21-lid-power-and-sleep.md)
> **Script:** [`scripts/display-utility`](../scripts/display-utility)

Written **2026-08-22**. Linux Mint 22.3, Cinnamon on **X11**, kernel 7.0.0-28-generic.

---

## 1. Why it exists

Cinnamon's Display panel offers **Join Displays** and **Mirror**. GNOME offers a
third mode, *Single Display*; Cinnamon does not. There is no "show only display 2"
button to find, which reads as a missing feature rather than a different design.

The equivalent does exist, but it is awkward in a specific way:

- Each monitor has an **enable toggle** (the switch beside *Set as Primary*).
- **Cinnamon will not let you switch off the primary display.**

So "show only the external" is a two-step dance in a fixed order — set the external
as primary *first*, only then switch the internal off. Do it in the other order and
the toggle is unavailable, which looks exactly like the feature being absent.

This tool makes it one command, and adds two things the panel does not have: a
revert guard, and a layout that reliably survives logout.

---

## 2. Install

The script lives in the repo; the copies on `PATH` and in the menu are pointers to
it, so there is one file to maintain.

```bash
ln -sf "$PWD/scripts/display-utility" ~/.local/bin/display-utility   # already on PATH
display-utility install-menu                                        # applications menu
display-utility autostart on                                        # re-apply at login
```

`~/.local/bin` is already on this machine's `PATH`. `install-menu` writes
`~/.local/share/applications/display-utility.desktop` and refreshes the desktop
database; `desktop-file-validate` passes it clean.

---

## 3. Commands

| Command | Effect |
|---|---|
| `display-utility` / `list` | Numbered list of connected outputs, `*` marks primary |
| `display-utility only 2` | Show on display 2 **only** — it becomes primary at `0x0`, everything else off |
| `display-utility only HDMI-1` | Same, addressed by xrandr name instead of number |
| `display-utility join [2 1]` | Extend across the named outputs, left to right. No arguments = all connected |
| `display-utility mirror` | Mirror every output onto the first |
| `display-utility save` | Remember the current layout |
| `display-utility restore` | Re-apply the remembered layout |
| `display-utility autostart on\|off` | Re-apply it automatically at login |
| `display-utility status` | Active layout, saved layout, autostart state |
| `display-utility menu` | Graphical picker — what the menu entry runs |
| `display-utility install-menu` / `remove-menu` | Add to / remove from the applications menu |

Flags: `-y` skips the revert guard, `-q` silences normal output, `--help` prints usage.

```
$ display-utility list
connected displays
    [1] eDP-1      off
  * [2] HDMI-1     on   2560x1080+0+0    800mm x 335mm
```

Numbers follow xrandr's own ordering, which is the same order Cinnamon numbers them
in — so `[2]` here is the `2` in the Display panel.

Applying any layout saves it automatically. `only 2` followed by `autostart on` is
the entire setup for a docked machine.

---

## 4. The revert guard

Every layout change is applied, then **held for 15 seconds awaiting confirmation**.
No answer reverts.

This is not ceremony. The failure mode being guarded against is switching output to
a display that turns out to be off, on the wrong input, or unable to take the mode —
at which point the confirmation dialog is on a screen you cannot see, and the only
way out is a TTY. Walking away has to be safe.

| Context | How it asks |
|---|---|
| Terminal | `read -t 15` prompt — `y` keeps, anything else reverts |
| Menu / GUI | `zenity --question --timeout=15` — *Keep* keeps; **Revert, closing it, or letting it time out all revert** |
| Not a terminal (autostart) | Skipped — otherwise every login would stall for 15 s |

`-y` skips it deliberately. The autostart path uses `-y` for exactly that reason.

---

## 5. Persistence — the part that actually needed solving

**A layout set with `xrandr` alone is runtime-only.** That much is expected. What is
not obvious is that going through Cinnamon's own panel was not sufficient either.

Observed on **2026-08-22**: the layout was set to HDMI-only, `csd-xrandr` wrote
`~/.config/cinnamon-monitors.xml`, and after a reboot the machine came back with the
**internal panel primary and the desktop extended again**. The file existed and was
correct; it simply was not applied.

> ⚠️ **Do not treat `cinnamon-monitors.xml` as proof of persistence.** It is written
> whether or not it is honoured. [`scripts/lid-dock-handoff.sh`](../scripts/lid-dock-handoff.sh)
> originally tested that file's existence as a persistence check and reported green
> while the mechanism was broken — a check that passes while the thing it checks
> fails is worse than no check. It now reports this tool's chain instead.

### The mechanism

`autostart on` writes `~/.config/autostart/display-utility-restore.desktop`:

```ini
Exec=bash -c 'sleep 4; <repo>/scripts/display-utility restore --quiet --yes'
```

The saved layout lives in `~/.local/state/display-utility/layout` as literal xrandr
arguments:

```
--output eDP-1 --off --output HDMI-1 --mode 2560x1080 --pos 0x0 --primary
```

**The 4-second delay is load-bearing.** `csd-xrandr` applies its own configuration
early in session startup; firing at the same moment is a race, and the loser's
layout is the one you get. Waiting lets Cinnamon finish, then overrides it.

Verified across the **16:08 reboot on 2026-08-22**: the machine came up with
`HDMI-1` primary at 2560×1080 and `eDP-1` off, geometry 2560×1080. Both mechanisms
now agree — Cinnamon's own file has since been rewritten to match — but the
autostart is what makes it a guarantee rather than a hope.

---

## 6. The graphical picker

`display-utility menu` builds its rows from what is connected at that moment:

```
Only display 1  —  eDP-1   (1920x1080)
Only display 2  —  HDMI-1  (2560x1080)  ★ primary
Join all displays  —  extend, left to right
Mirror all displays
Save current layout as the login default
```

Join and Mirror are offered only when more than one display is connected, since
neither means anything with one.

The menu entry carries keywords for `display`, `displays`, `monitor`, `monitors`,
`screen`, `screens`, `xrandr`, `resolution`, `external`, `hdmi`, `projector`,
`dual`, `single` and `layout`, so it surfaces next to Cinnamon's own Display panel
under Preferences.

---

## 7. Limits and troubleshooting

- **X11 only.** This machine runs `XDG_SESSION_TYPE=x11` with `X-Cinnamon`. Under
  Wayland `xrandr` cannot reconfigure outputs and the tool exits with a message
  rather than half-working.
- **`restore` is all-or-nothing.** If a saved output is no longer connected, xrandr
  rejects the entire call rather than the one stanza. The tool says so explicitly
  instead of failing opaquely. Re-save after a hardware change.
- **Mirroring forces a common mode**, so a 2560×1080 ultrawide mirrored against a
  1920×1080 panel will letterbox. Expected, not a fault.
- **A KVM that drops EDID on switch** will disconnect the output, and a saved layout
  naming it can then fail to restore. This is the same EDID-retention issue that
  [22 §8](22-drive-migration.md) and [21 §7](21-lid-power-and-sleep.md) both flag as
  the main KVM purchasing criterion.
- **Recovering blind:** if a layout leaves you with no usable screen and the guard
  was skipped, switch to a TTY with `Ctrl+Alt+F2`, log in, and run
  `DISPLAY=:0 display-utility only 1` (the internal panel) or
  `DISPLAY=:0 xrandr --auto`.
