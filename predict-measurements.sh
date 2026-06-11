#!/usr/bin/env bash
# CI wrapper for predict-measurements.py: loop-mounts the image's ESP and
# predicts RTMR[1]/RTMR[2] from the artifact. Requires root (losetup/mount).
#
# Usage: predict-measurements.sh <raw-image> <out.json>
set -euo pipefail

RAW="$1"
OUT_JSON="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"

LOOPDEV=$(losetup --find --show --partscan "$RAW")
trap 'umount /tmp/predict-esp 2>/dev/null || true; losetup -d "$LOOPDEV"' EXIT
partprobe "$LOOPDEV" 2>/dev/null || true
sleep 1

ESP_PART=""
for part in "${LOOPDEV}p"*; do
  TYPE=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
  [ "$TYPE" = "vfat" ] && ESP_PART="$part"
done
[ -n "$ESP_PART" ] || { echo "ERROR: no vfat ESP partition found in $RAW" >&2; exit 1; }

mkdir -p /tmp/predict-esp
mount -o ro "$ESP_PART" /tmp/predict-esp

python3 "$HERE/predict-measurements.py" \
  --image "$RAW" --esp /tmp/predict-esp --json "$OUT_JSON"
