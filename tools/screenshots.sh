#!/usr/bin/env bash
# Runs the app in its demo mode on an iOS simulator and takes a screenshot per step.
# usage: tools/screenshots.sh <path/to/VitaIRC.app> <output dir> [language]
set -euo pipefail
APP="$1"; OUT="$2"; LANG_CODE="${3:-en}"
ID=io.github.archelkrozt.vitairc
DEV="${SIM_DEVICE:-iPhone 16}"
mkdir -p "$OUT"
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl status_bar "$DEV" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 || true
xcrun simctl uninstall "$DEV" "$ID" 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_VITAIRC_DEMO=1 xcrun simctl launch "$DEV" "$ID" -AppleLanguages "($LANG_CODE)" >/dev/null
DATA=$(xcrun simctl get_app_container "$DEV" "$ID" data)
STEP_FILE="$DATA/Documents/demo_step.txt"
last=""
for i in $(seq 1 1200); do
  sleep 0.5
  step=$(cat "$STEP_FILE" 2>/dev/null || true)
  [ "$step" = "$last" ] && continue
  last="$step"
  [ "$step" = "done" ] && break
  [ -z "$step" ] && continue
  sleep 0.6
  xcrun simctl io "$DEV" screenshot "$OUT/$step.png" >/dev/null 2>&1 && echo "$step"
  # the app waits for this before going on
  printf '%s' "$step" > "$DATA/Documents/demo_ack.txt"
done
cp "$DATA/Documents/demo_log.txt" "$OUT/demo_log.txt" 2>/dev/null || true
xcrun simctl terminate "$DEV" "$ID" || true
