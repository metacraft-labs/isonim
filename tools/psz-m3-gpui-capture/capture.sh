#!/usr/bin/env bash
# Captures the editor's GPUI page preview: Fit (the default), 100% by the zoom
# control, or 100% opened by the URL. See README.md for what must be running
# first (the editor server, the GPUI launcher) and how to build the driver.
#
#   PSZ_M3_GPUI_FRAMES=/tmp/fit CAPTURE_DRIVER=... NODE=... CHROMIUM=... \
#     GUI_ASSERT_DIR=... ./capture.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GUI_ASSERT_DIR:?set GUI_ASSERT_DIR to a GuiAssert checkout}"
: "${CAPTURE_DRIVER:?set CAPTURE_DRIVER to the capture_driver binary (README.md)}"
: "${NODE:?set NODE to a node binary}"
: "${CHROMIUM:?set CHROMIUM to a chromium binary}"
: "${PSZ_M3_GPUI_FRAMES:?set PSZ_M3_GPUI_FRAMES to an empty output directory}"
export PSZ_M3_URL="${PSZ_M3_URL:-http://127.0.0.1:18691/index.html?view=page&storyGroup=Pages&story=Trip%20Planner&kind=page&index=0&viewport=desktop&zoom=fit}"
export PSZ_M3_STATES="${PSZ_M3_STATES:-fit,actual}"
export PSZ_M3_OUTPUT="${PSZ_M3_OUTPUT:-1920,1200}"
export PSZ_M3_WINDOW="${PSZ_M3_WINDOW:-1920,1200}"
# The driver hands over through files in this directory, so a stale file from
# an earlier run would be read as a request or as a finished run.
if [ -d "$PSZ_M3_GPUI_FRAMES" ] && [ -n "$(ls -A "$PSZ_M3_GPUI_FRAMES")" ]; then
  echo "capture.sh: $PSZ_M3_GPUI_FRAMES is not empty" >&2
  exit 2
fi
mkdir -p "$PSZ_M3_GPUI_FRAMES"
nix develop "$GUI_ASSERT_DIR" --command env NODE="$NODE" CHROMIUM="$CHROMIUM" \
  PSZ_M3_DRIVE="$here/drive.mjs" PSZ_M3_URL="$PSZ_M3_URL" \
  PSZ_M3_GPUI_FRAMES="$PSZ_M3_GPUI_FRAMES" PSZ_M3_STATES="$PSZ_M3_STATES" \
  PSZ_M3_OUTPUT="$PSZ_M3_OUTPUT" PSZ_M3_WINDOW="$PSZ_M3_WINDOW" "$CAPTURE_DRIVER"
