#!/usr/bin/env bash
# Captures the editor's GPUI page preview: Fit (the default), 100% by the zoom
# control, or 100% opened by the URL. See README.md for what must be running
# first (the editor server, the GPUI launcher) and how to build the driver.
# Each capture writes PNGs beside its PPMs and a <state>.sidecar.json (sidecar.py)
# with the frame source the page declared, the renderer, the tree commits, the
# window and the painted box.
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
# The trees the frames came from. The sidecars record their HEAD commits and
# whether they are dirty, so a capture names the build it measured. Point these
# at the checkouts that were built and served (the defaults are the workspace
# siblings of this script's checkout).
export ISONIM_TREE="${ISONIM_TREE:-$here/../..}"
export RENDER_SERVE_TREE="${RENDER_SERVE_TREE:-$here/../../../isonim-render-serve}"
export EXAMPLES_TREE="${EXAMPLES_TREE:-$here/../../../isonim-examples}"
for ppm in "$PSZ_M3_GPUI_FRAMES"/*.ppm; do
  python3 "$here/ppm_to_png.py" "$ppm" "${ppm%.ppm}.png"
done
python3 "$here/sidecar.py" --frames "$PSZ_M3_GPUI_FRAMES" --capture gpui \
  --window "$PSZ_M3_WINDOW" --states "$PSZ_M3_STATES" \
  --isonim-tree "$ISONIM_TREE" --render-serve-tree "$RENDER_SERVE_TREE" \
  --examples-tree "$EXAMPLES_TREE"
