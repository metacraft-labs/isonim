#!/usr/bin/env python3
"""Writes one sidecar JSON per PSZ-M3 capture state, next to its frames.

A capture state is one of fit, actual or actual-wide. Each GPUI state has a
shown and a hidden PPM (see README.md); each web state has page and frame PNGs.
The sidecar records what the frames came from:

  frameSource  the source the page declared for the streamed frames, read from
               the zoom stage's data-preview-frame-declared attribute. The page
               sets that attribute from the launcher's hello
               (capabilities.frameSource), so the value is what the launcher
               reported, not a value this script knows. "none" when the page
               declares nothing (the web iframe preview, or an empty value).
  renderer     the renderer behind the frames: "synthetic raster" and
               "gpui headless" for a streamed frame, from the declared source;
               "web iframe" for the web preview.
  commits      the HEAD commit of the isonim, render-serve and examples trees,
               and how many entries git status reports for each (0 is clean).
  window       the chromium window size the capture was taken at.
  paintedBox   the box the streamed frame paints: the bounding box of the pixels
               where the shown and hidden PPMs differ by more than 24 on some
               channel (the rule paintedBox uses in
               tests/test_editor_preview_streamed_zoom.nim). For web it is the
               visible frame measured in the page, in CSS px.

Usage:
  sidecar.py --frames DIR --capture gpui --window W,H \
      --isonim-tree P --render-serve-tree P --examples-tree P [--states a,b,c]
  sidecar.py --frames DIR --capture web --isonim-tree P ...   (web: window from the page)

The writer reads only files in DIR and git state of the trees; it needs no
browser and no network, so tests/test_sidecar.py runs it on fixtures.
"""
import argparse
import json
import os
import subprocess
import sys

SCHEMA = "psz-m3-capture-sidecar/1"
STATES = ("fit", "actual", "actual-wide")
# The same threshold as paintedBox in tests/test_editor_preview_streamed_zoom.nim.
PAINT_THRESHOLD = 24


def read_ppm(path):
    """Returns (width, height, pixels) of a binary P6 PPM; pixels is bytes."""
    with open(path, "rb") as f:
        data = f.read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1  # the single whitespace byte after maxval
    if fields[0] != b"P6" or fields[3] != b"255":
        raise ValueError(f"{path}: not a binary P6 PPM with maxval 255")
    width, height = int(fields[1]), int(fields[2])
    pixels = data[pos:]
    if len(pixels) != width * height * 3:
        raise ValueError(f"{path}: pixel data is {len(pixels)} bytes, not {width * height * 3}")
    return width, height, pixels


def painted_box(shown_path, hidden_path):
    """The bounding box where the two captures differ, or None when they match.

    Returns {"x", "y", "width", "height"} in pixels of the captures.
    """
    width, height, shown = read_ppm(shown_path)
    w2, h2, hidden = read_ppm(hidden_path)
    if (width, height) != (w2, h2):
        raise ValueError(f"shown is {width}x{height}, hidden is {w2}x{h2}")
    row_bytes = width * 3
    min_x, min_y, max_x, max_y = width, height, -1, -1
    for y in range(height):
        a = shown[y * row_bytes:(y + 1) * row_bytes]
        b = hidden[y * row_bytes:(y + 1) * row_bytes]
        if a == b:
            continue  # the common case: most rows of the window do not differ
        for x in range(width):
            i = x * 3
            if max(abs(a[i + c] - b[i + c]) for c in range(3)) > PAINT_THRESHOLD:
                min_x, max_x = min(min_x, x), max(max_x, x)
                min_y, max_y = min(min_y, y), max(max_y, y)
    if max_x < 0:
        return None
    return {"x": min_x, "y": min_y, "width": max_x - min_x + 1, "height": max_y - min_y + 1}


def renderer_for(capture, frame_source):
    """The renderer name a frame source stands for."""
    if capture == "web":
        return "web iframe"
    if frame_source == "synthetic":
        return "synthetic raster"
    if frame_source == "real":
        return "gpui headless"
    return "gpui (no declared source)"


def frame_source_from_page(measured):
    """The declared source from a measured page state; "none" when absent or empty."""
    declared = measured.get("frameSource")
    return declared if isinstance(declared, str) and declared else "none"


def tree_commit(tree):
    """The HEAD sha and the number of git status entries of a checkout."""
    sha = subprocess.run(["git", "-C", tree, "rev-parse", "HEAD"], check=True,
                         capture_output=True, text=True).stdout.strip()
    status = subprocess.run(["git", "-C", tree, "status", "--porcelain"], check=True,
                            capture_output=True, text=True).stdout
    return {"sha": sha, "dirtyEntries": len([line for line in status.splitlines() if line])}


def parse_size(text):
    w, h = text.split(",")
    return {"width": int(w), "height": int(h)}


def build_sidecar(capture, state, window, trees, measured, painted, captured=None):
    """Builds the sidecar dict for one state. Pure apart from the git reads in trees."""
    source = frame_source_from_page(measured) if capture == "gpui" else "none"
    if capture == "gpui":
        from_page = ("the zoom stage's data-preview-frame-declared, set from the launcher's "
                     "hello capabilities.frameSource")
    else:
        from_page = "no streamed frame: the web preview is an iframe and declares no source"
    sidecar = {
        "schema": SCHEMA,
        "capture": capture,
        "state": state,
        "frameSource": source,
        "frameSourceFrom": from_page,
        "renderer": renderer_for(capture, source),
        "commits": {name: tree_commit(path) for name, path in trees.items()},
        "window": window,
        "paintedBox": painted,
        "paintedBoxSource": ("shown minus hidden PPM, threshold %d" % PAINT_THRESHOLD
                             if capture == "gpui" else "visible frame in the page, CSS px"),
        "pageState": {k: measured.get(k) for k in (
            "areaWidth", "areaHeight", "scale", "readout", "wrapperRect",
            "canvasCssWidth", "canvasCssHeight", "frameSourceLabel", "viewport", "visible",
            "stage", "scrollPort") if k in measured},
    }
    if captured is not None:
        sidecar["capturedPpm"] = captured
    return sidecar


def write_gpui(frames, state, window, trees):
    with open(os.path.join(frames, state + ".json")) as f:
        measured = json.load(f)
    shown = os.path.join(frames, state + "-shown.ppm")
    hidden = os.path.join(frames, state + "-hidden.ppm")
    width, height, _ = read_ppm(shown)
    painted = painted_box(shown, hidden)
    sidecar = build_sidecar("gpui", state, window, trees, measured, painted,
                            captured={"width": width, "height": height})
    sidecar["files"] = {"shown": state + "-shown.ppm", "hidden": state + "-hidden.ppm"}
    return sidecar


def write_web(frames, state, trees):
    with open(os.path.join(frames, "web-" + state + ".json")) as f:
        measured = json.load(f)
    visible = measured["visible"]
    painted = {"x": round(visible["x"]), "y": round(visible["y"]),
               "width": round(visible["w"]), "height": round(visible["h"])}
    window = parse_size("%d,%d" % tuple(measured["viewport"]))
    sidecar = build_sidecar("web", state, window, trees, measured, painted)
    sidecar["files"] = {"page": "web-%s-page.png" % state, "frame": "web-%s-frame.png" % state}
    return sidecar


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--frames", required=True)
    p.add_argument("--capture", required=True, choices=("gpui", "web"))
    p.add_argument("--window", default="", help="W,H of the chromium window (gpui)")
    p.add_argument("--states", default=",".join(STATES))
    p.add_argument("--isonim-tree", required=True)
    p.add_argument("--render-serve-tree", required=True)
    p.add_argument("--examples-tree", required=True)
    args = p.parse_args(argv)
    trees = {"isonim": args.isonim_tree, "renderServe": args.render_serve_tree,
             "examples": args.examples_tree}
    window = parse_size(args.window) if args.window else None
    for state in args.states.split(","):
        if args.capture == "gpui":
            if window is None:
                p.error("--window is required for gpui captures")
            sidecar = write_gpui(args.frames, state, window, trees)
            out = os.path.join(args.frames, state + ".sidecar.json")
        else:
            sidecar = write_web(args.frames, state, trees)
            out = os.path.join(args.frames, "web-" + state + ".sidecar.json")
        with open(out, "w") as f:
            json.dump(sidecar, f, indent=1)
            f.write("\n")
        print("sidecar:", out, "frameSource=" + sidecar["frameSource"],
              "renderer=" + sidecar["renderer"], "paintedBox=" + json.dumps(sidecar["paintedBox"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
