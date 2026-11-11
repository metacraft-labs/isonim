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
  commits      the HEAD commit of the checkout at each tree path given, and how
               many entries git status reports for it (0 is clean). These name
               the checkouts that were served or run; they do not prove what the
               launcher process was built from.
  window       the window size the capture was requested at (--window, which
               capture.sh passes from PSZ_M3_WINDOW). It is not a size measured
               from chromium; the captured PPM size is recorded as capturedPpm.
  paintedBox   the box the streamed frame paints: the bounding box of the pixels
               where the shown and hidden PPMs differ by more than 24 on some
               channel (the rule paintedBox uses in
               tests/test_editor_preview_streamed_zoom.nim). For web it is the
               visible frame measured in the page, in CSS px.
  files        each image the sidecar describes, with the sha256 and the UTC
               capture time taken when the image was written, and the runId of
               that capture run.

Freshness. The writer refuses to describe an image it cannot tie to its own
capture run. Each capture records every image's sha256 and capture time at the
moment the image is written: web_capture.mjs does it into the state's JSON
(`captures`), and capture.sh does it through `--record` into captures.json for
the GPUI PPMs and PNGs. The writer hashes each file again and raises
CaptureRefused when an image is missing, has no record, or its digest differs
from the one taken at capture (an image copied from an older run, or changed
after the capture). Nothing is written in that case.

Usage:
  sidecar.py --frames DIR --record FILE [FILE ...]           (capture.sh, after each write)
  sidecar.py --frames DIR --capture gpui --window W,H \
      --isonim-tree P --render-serve-tree P --examples-tree P [--states a,b,c]
  sidecar.py --frames DIR --capture web --isonim-tree P ...   (web: window from the page)

The writer reads only files in DIR and git state of the trees; it needs no
browser and no network, so tests/test_sidecar.py runs it on fixtures.
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import uuid

SCHEMA = "psz-m3-capture-sidecar/2"
STATES = ("fit", "actual", "actual-wide")
# The same threshold as paintedBox in tests/test_editor_preview_streamed_zoom.nim.
PAINT_THRESHOLD = 24
# The capture-time record of the GPUI images (written by --record).
CAPTURES_FILE = "captures.json"


class CaptureRefused(ValueError):
    """The writer will not describe an image it cannot tie to its own capture run."""


def sha256_file(path):
    """The lowercase hex sha256 of a file's bytes."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now():
    """The current time as an ISO 8601 UTC string, to the second, with a Z suffix."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_captures(frames):
    """The captures.json of a frames directory, or an empty record when none exists."""
    path = os.path.join(frames, CAPTURES_FILE)
    if not os.path.exists(path):
        return {"runId": None, "captures": {}}
    with open(path) as f:
        return json.load(f)


def record_capture(frames, path, run_id=None):
    """Hashes one image at capture time into frames/captures.json.

    Called by capture.sh right after each PPM and PNG is written. The first
    record of a file is kept: recording the same file again with the same bytes
    is a no-op, and with different bytes it is refused, so a file cannot be
    re-recorded to match a copy from another run.
    """
    name = os.path.basename(path)
    digest = sha256_file(path)
    record = read_captures(frames)
    if record["runId"] is None:
        record["runId"] = run_id or str(uuid.uuid4())
    existing = record["captures"].get(name)
    if existing is not None:
        if existing["sha256"] != digest:
            raise CaptureRefused(f"{name}: already recorded with sha256 {existing['sha256']}, "
                                 f"now {digest}; refusing to re-record a changed image")
        return existing
    entry = {"sha256": digest, "capturedAt": utc_now()}
    record["captures"][name] = entry
    with open(os.path.join(frames, CAPTURES_FILE), "w") as f:
        json.dump(record, f, indent=1)
        f.write("\n")
    return entry


def verify_image(frames, name, recorded):
    """Checks that frames/name is the image recorded at capture, and returns its file entry.

    recorded is the capture-time entry ({"sha256", "capturedAt"}) or None when
    the capture recorded nothing for this image.
    """
    path = os.path.join(frames, name)
    if not os.path.isfile(path):
        raise CaptureRefused(f"{path}: image missing")
    if recorded is None:
        raise CaptureRefused(f"{name}: no digest was recorded at capture")
    digest = sha256_file(path)
    if digest != recorded["sha256"]:
        raise CaptureRefused(f"{name}: sha256 {digest} differs from the {recorded['sha256']} "
                             f"taken at capture {recorded['capturedAt']}; not this run's image")
    return {"path": name, "sha256": digest, "capturedAt": recorded["capturedAt"]}


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
    record = read_captures(frames)
    names = {"shown": state + "-shown.ppm", "hidden": state + "-hidden.ppm",
             "shownPng": state + "-shown.png", "hiddenPng": state + "-hidden.png"}
    # Every image is verified before anything is read from it, so a stale PPM
    # cannot paint a box the PNG beside it does not show.
    files = {key: verify_image(frames, name, record["captures"].get(name))
             for key, name in names.items()}
    shown = os.path.join(frames, names["shown"])
    hidden = os.path.join(frames, names["hidden"])
    width, height, _ = read_ppm(shown)
    painted = painted_box(shown, hidden)
    sidecar = build_sidecar("gpui", state, window, trees, measured, painted,
                            captured={"width": width, "height": height})
    sidecar["files"] = files
    sidecar["runId"] = record["runId"]
    return sidecar


def write_web(frames, state, trees):
    with open(os.path.join(frames, "web-" + state + ".json")) as f:
        measured = json.load(f)
    visible = measured["visible"]
    painted = {"x": round(visible["x"]), "y": round(visible["y"]),
               "width": round(visible["w"]), "height": round(visible["h"])}
    window = parse_size("%d,%d" % tuple(measured["viewport"]))
    # web_capture.mjs records each PNG's digest when it screenshots it. The page
    # frame is needed only when a visible frame was measured.
    recorded = measured.get("captures") or {}
    names = {"page": "web-%s-page.png" % state}
    if visible["w"] > 0 and visible["h"] > 0:
        names["frame"] = "web-%s-frame.png" % state
    files = {}
    for key, name in names.items():
        entry = recorded.get(key)
        if entry is not None and entry.get("file") != name:
            raise CaptureRefused(f"{name}: the capture recorded {entry.get('file')} for {key}")
        files[key] = verify_image(frames, name, entry)
    sidecar = build_sidecar("web", state, window, trees, measured, painted)
    sidecar["files"] = files
    sidecar["runId"] = measured.get("runId")
    return sidecar


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--frames", required=True)
    p.add_argument("--record", nargs="+", metavar="FILE",
                   help="record the sha256 of these images (capture.sh) and exit")
    p.add_argument("--capture", choices=("gpui", "web"))
    p.add_argument("--window", default="", help="W,H of the chromium window (gpui)")
    p.add_argument("--states", default=",".join(STATES))
    p.add_argument("--isonim-tree")
    p.add_argument("--render-serve-tree")
    p.add_argument("--examples-tree")
    args = p.parse_args(argv)
    if args.record:
        for path in args.record:
            record_capture(args.frames, path)
        return 0
    for required in ("capture", "isonim_tree", "render_serve_tree", "examples_tree"):
        if getattr(args, required) is None:
            p.error("--%s is required to write a sidecar" % required.replace("_", "-"))
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
    try:
        sys.exit(main())
    except CaptureRefused as refusal:
        print("sidecar: refused:", refusal, file=sys.stderr)
        sys.exit(3)
