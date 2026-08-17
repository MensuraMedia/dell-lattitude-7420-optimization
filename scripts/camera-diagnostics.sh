#!/usr/bin/env bash
#
# camera-diagnostics.sh — Dell Latitude 7420 integrated webcam characterisation
#
# STRICTLY READ-ONLY with respect to system configuration. This script never
# writes a V4L2 control, never captures an image, and never modifies anything.
# Throughput measurement is OPT-IN (--throughput) and discards all frames to
# /dev/null — no image data is ever written to disk.
#
# The webcam's USB iManufacturer field on this platform is a unit-unique serial
# that leaks into /dev/v4l/by-id/ paths with no "Serial:" prefix, so the patterns
# in collect-diagnostics.sh do NOT catch it. It is REDACTED here by default.
#
# Usage:
#   ./scripts/camera-diagnostics.sh                  # redacted (default)
#   ./scripts/camera-diagnostics.sh --throughput     # + measure sustained fps
#   ./scripts/camera-diagnostics.sh --no-redact      # full, DO NOT COMMIT
#   ./scripts/camera-diagnostics.sh -o /path/out.md
#
# Reference: docs/21-camera-and-imaging.md
#
set -uo pipefail

REDACT=1
THROUGHPUT=0
OUTFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-redact)  REDACT=0; shift ;;
    --throughput) THROUGHPUT=1; shift ;;
    -o|--output)  OUTFILE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v v4l2-ctl >/dev/null 2>&1 || {
  echo "v4l2-ctl not found. Install with: sudo apt-get install -y v4l-utils" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
[[ -z "$OUTFILE" ]] && OUTFILE="${REPO_ROOT}/diagnostics/camera-${STAMP}.md"
mkdir -p "$(dirname "$OUTFILE")"

VID=1bcf
PID=2ba0

# Redact the bare, unprefixed webcam serial wherever it appears — in by-id paths,
# in lsusb iManufacturer output, and anywhere else. Also covers the generic
# prefixed forms so this script is safe standalone.
redact() {
  if [[ $REDACT -eq 1 ]]; then
    sed -E \
      -e 's/usb-[A-Z0-9]{12,24}_Integrated_Webcam/usb-[REDACTED]_Integrated_Webcam/g' \
      -e 's/(iManufacturer[[:space:]]+[0-9]+[[:space:]]+)[A-Z0-9]{12,24}/\1[REDACTED]/g' \
      -e 's/([Ss]erial [Nn]umber:[[:space:]]*)[A-Za-z0-9_-]+/\1[REDACTED]/g' \
      -e 's/([Ss]erial:[[:space:]]*)[A-Za-z0-9_-]+/\1[REDACTED]/g' \
      -e 's/\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b/[MAC-REDACTED]/g' \
      -e 's/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/[UUID-REDACTED]/g'
  else
    cat
  fi
}

section() { printf '\n## %s\n\n' "$1" >> "$OUTFILE"; }
fence()   { printf '```\n' >> "$OUTFILE"; }

# Emit a fenced block from a command, redacted.
block() {
  fence
  { eval "$*" 2>&1 || echo "(command failed or produced no output)"; } | redact >> "$OUTFILE"
  fence
}

{
  echo "# Camera diagnostics — Dell Latitude 7420"
  echo
  echo "- **Captured:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- **Kernel:** $(uname -r)"
  echo "- **Device:** \`${VID}:${PID}\` Integrated_Webcam_FHD"
  echo "- **Redaction:** $([[ $REDACT -eq 1 ]] && echo 'ENABLED (safe to commit)' || echo '*** DISABLED — DO NOT COMMIT ***')"
  echo "- **Reference:** [docs/21-camera-and-imaging.md](../docs/21-camera-and-imaging.md)"
} > "$OUTFILE"

section "USB device descriptor"
block "lsusb -v -d ${VID}:${PID} 2>/dev/null | sed -n '1,45p'"

section "Interface map (dual-function check)"
echo "Expect two Interface Association Descriptors: if 0+1 = RGB, if 2+3 = IR." >> "$OUTFILE"
block "lsusb -v -d ${VID}:${PID} 2>/dev/null | grep -E 'bFirstInterface|bInterfaceCount|bFunctionClass|bInterfaceNumber|bInterfaceSubClass' | sed 's/^[[:space:]]*//'"

section "V4L2 node topology"
block "v4l2-ctl --list-devices"

section "Per-node capabilities and formats"
for d in /dev/video*; do
  [[ -e "$d" ]] || continue
  printf '\n### %s\n\n' "$d" >> "$OUTFILE"
  block "v4l2-ctl -d $d --info | grep -E 'Driver name|Card type|Bus info|Device Caps' ; echo '--- formats ---' ; v4l2-ctl -d $d --list-formats-ext 2>&1 | grep -vE '^ioctl|^\s*$'"
done

section "Control surface"
for d in /dev/video0 /dev/video2; do
  [[ -e "$d" ]] || continue
  printf '\n### %s\n\n' "$d" >> "$OUTFILE"
  block "v4l2-ctl -d $d --list-ctrls"
done

section "Stable device selectors"
echo "\`by-id\` covers only the RGB function. Use \`by-path\`: \`:1.0\` = RGB, \`:1.2\` = IR." >> "$OUTFILE"
links() { ls -l "$1" 2>/dev/null | awk 'NF>3 {printf "%-58s -> %s\n", $(NF-2), $NF}'; }
block "echo '--- by-id ---'; links /dev/v4l/by-id/; echo '--- by-path ---'; links /dev/v4l/by-path/"

section "Access-control model"
echo "Access is granted by systemd-logind per-seat ACL, not \`video\` group membership." >> "$OUTFILE"
block "ls -l /dev/video0 /dev/video2; echo '--- groups ---'; groups; echo '--- acl ---'; getfacl -p /dev/video0 2>/dev/null | grep -v '^#'"

section "Power management"
block "for f in control runtime_status autosuspend_delay_ms; do printf '%-24s %s\n' \"\$f\" \"\$(cat /sys/bus/usb/devices/3-6/power/\$f 2>/dev/null)\"; done"

section "uvcvideo module parameters"
echo "\`quirks=4294967295\` is the \`(unsigned)-1\` 'no override' sentinel — not 'all quirks on'." >> "$OUTFILE"
block "for f in /sys/module/uvcvideo/parameters/*; do printf '%-16s %s\n' \"\$(basename \$f)\" \"\$(cat \$f 2>/dev/null)\"; done"

section "Dell privacy driver events"
echo "Unmapped keycodes here mean privacy events never reach userspace (docs/21 §8)." >> "$OUTFILE"
block "grep -A8 -i 'Dell Privacy' /proc/bus/input/devices 2>/dev/null; echo '--- kernel messages ---'; dmesg 2>/dev/null | grep -iE 'privacy|uvcvideo' | tail -20"

section "Exclusive-access check"
block "fuser -v /dev/video0 /dev/video2 2>&1 || echo 'no process holding either node'"

if [[ $THROUGHPUT -eq 1 ]]; then
  section "Sustained throughput (frames discarded)"
  if command -v ffmpeg >/dev/null 2>&1; then
    echo "Declared 1080p rate is 30 fps. A result near 22 fps indicates" >> "$OUTFILE"
    echo "\`exposure_dynamic_framerate=1\` trading framerate for exposure (docs/21 §6.2)." >> "$OUTFILE"
    CUR="$(v4l2-ctl -d /dev/video0 -C exposure_dynamic_framerate 2>/dev/null | awk '{print $2}')"
    block "echo 'exposure_dynamic_framerate = ${CUR:-unknown}'; timeout 30 ffmpeg -hide_banner -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video0 -t 5 -f null - 2>&1 | grep -oE 'fps= *[0-9]+' | tail -1"
  else
    echo "_ffmpeg not installed — throughput test skipped._" >> "$OUTFILE"
  fi
fi

{
  echo
  echo "---"
  echo
  echo "_Generated by \`scripts/camera-diagnostics.sh\`. No image data was captured._"
} >> "$OUTFILE"

if [[ $REDACT -eq 0 ]]; then
  echo "WARNING: redaction was DISABLED. This file contains the webcam serial." >&2
fi

echo "Wrote $OUTFILE"
