"""Fixture tests for sidecar.py: the painted box, the frame source, a full write, and freshness.

These need no browser, no sway and no editor server. Each test builds its own
PPM, PNG and JSON fixtures in a temporary directory, and a temporary git checkout
for the commit fields, so the result depends only on this file and sidecar.py.
The fixture PNGs are arbitrary bytes: the writer hashes an image and never
decodes it, so the freshness rules do not depend on a PNG encoder.
Run: python3 -m unittest -v test_sidecar.py   (from this directory)
"""
import datetime
import functools
import hashlib
import http.server
import io
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from contextlib import redirect_stdout

import editor_bundle
import sidecar


def write_ppm(path, width, height, pixel):
    """A P6 PPM filled with pixel(x, y) -> (r, g, b)."""
    body = bytearray()
    for y in range(height):
        for x in range(width):
            body.extend(pixel(x, y))
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (width, height) + bytes(body))


def write_bytes(path, data):
    with open(path, "wb") as f:
        f.write(data)


def sha(data):
    """The sha256 of bytes, computed here rather than by sidecar.py."""
    return hashlib.sha256(data).hexdigest()


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid"))


def write_bundle_record(frames):
    """A bundle.json as editor_bundle.py writes it. The fixture runs do not serve an editor, so
    the sidecar tests use this record; BundleTest checks the real record against a real server."""
    with open(os.path.join(frames, sidecar.BUNDLE_FILE), "w") as f:
        json.dump({"url": "http://127.0.0.1:0", "files": {}, "treeHead": "fixture"}, f)


class PaintedBoxTest(unittest.TestCase):
    def test_box_is_the_region_where_the_captures_differ(self):
        with tempfile.TemporaryDirectory() as d:
            shown = os.path.join(d, "shown.ppm")
            hidden = os.path.join(d, "hidden.ppm")
            # 6x4 window; the frame paints x 2..3, y 1..2. A channel delta of 24 is
            # not a paint (the threshold is strictly greater), 25 is.
            write_ppm(shown, 6, 4, lambda x, y: (25, 25, 25) if (x, y) in {(2, 1), (3, 2)} else (9, 9, 9))
            write_ppm(hidden, 6, 4, lambda x, y: (0, 0, 0) if (x, y) in {(2, 1), (3, 2)} else (9, 9, 9))
            self.assertEqual(sidecar.painted_box(shown, hidden),
                             {"x": 2, "y": 1, "width": 2, "height": 2})

    def test_delta_at_threshold_is_not_painted(self):
        with tempfile.TemporaryDirectory() as d:
            shown = os.path.join(d, "shown.ppm")
            hidden = os.path.join(d, "hidden.ppm")
            write_ppm(shown, 3, 2, lambda x, y: (24, 0, 0))
            write_ppm(hidden, 3, 2, lambda x, y: (0, 0, 0))
            self.assertIsNone(sidecar.painted_box(shown, hidden))

    def test_size_mismatch_is_an_error(self):
        with tempfile.TemporaryDirectory() as d:
            shown = os.path.join(d, "shown.ppm")
            hidden = os.path.join(d, "hidden.ppm")
            write_ppm(shown, 3, 2, lambda x, y: (0, 0, 0))
            write_ppm(hidden, 2, 2, lambda x, y: (0, 0, 0))
            with self.assertRaises(ValueError):
                sidecar.painted_box(shown, hidden)


class FrameSourceTest(unittest.TestCase):
    def test_declared_value_is_taken_from_the_page(self):
        self.assertEqual(sidecar.frame_source_from_page({"frameSource": "synthetic"}), "synthetic")
        self.assertEqual(sidecar.frame_source_from_page({"frameSource": "real"}), "real")

    def test_empty_or_absent_declaration_is_none(self):
        self.assertEqual(sidecar.frame_source_from_page({"frameSource": ""}), "none")
        self.assertEqual(sidecar.frame_source_from_page({}), "none")
        self.assertEqual(sidecar.frame_source_from_page({"frameSource": None}), "none")

    def test_renderer_names(self):
        self.assertEqual(sidecar.renderer_for("gpui", "synthetic"), "synthetic raster")
        self.assertEqual(sidecar.renderer_for("gpui", "real"), "gpui headless")
        self.assertEqual(sidecar.renderer_for("gpui", "none"), "gpui (no declared source)")
        self.assertEqual(sidecar.renderer_for("web", "none"), "web iframe")


class CaptureFixtures(unittest.TestCase):
    """Builds capture runs the way capture.sh and web_capture.mjs do, in temporary directories."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.isonim = os.path.join(self.root, "isonim")
        self.serve = os.path.join(self.root, "render-serve")
        self.examples = os.path.join(self.root, "examples")
        for tree in (self.isonim, self.serve, self.examples):
            os.makedirs(tree)
            git(tree, "init", "-q")
            with open(os.path.join(tree, "f.txt"), "w") as f:
                f.write(tree)
            git(tree, "add", "f.txt")
            git(tree, "commit", "-q", "-m", "fixture")
        # A dirty entry in isonim must show up in the count.
        with open(os.path.join(self.isonim, "untracked.txt"), "w") as f:
            f.write("x")
        self.counter = 0

    def tearDown(self):
        self.tmp.cleanup()

    def new_dir(self, name):
        self.counter += 1
        path = os.path.join(self.root, "%s-%d" % (name, self.counter))
        os.makedirs(path)
        return path

    def trees(self):
        return {"isonim": self.isonim, "renderServe": self.serve, "examples": self.examples}

    def gpui_run(self, name, declared_value="synthetic", shown_png=b"shown-run", hidden_png=b"hidden-run"):
        """A GPUI fit capture run: PPMs and PNGs written, each recorded as capture.sh does."""
        frames = self.new_dir(name)
        measured = {"areaWidth": 8, "readout": "100%"}
        if declared_value is not None:
            measured["frameSource"] = declared_value
        with open(os.path.join(frames, "fit.json"), "w") as f:
            json.dump(measured, f)
        # The frame area is two slabs, as the synthetic raster paints them: the top
        # three rows are one colour, the bottom two another.
        write_ppm(os.path.join(frames, "fit-shown.ppm"), 8, 5,
                  lambda x, y: ((200, 200, 200) if y < 3 else (100, 100, 100)) if x >= 4 else (1, 1, 1))
        write_ppm(os.path.join(frames, "fit-hidden.ppm"), 8, 5, lambda x, y: (1, 1, 1))
        write_bytes(os.path.join(frames, "fit-shown.png"), shown_png)
        write_bytes(os.path.join(frames, "fit-hidden.png"), hidden_png)
        for image in ("fit-shown.ppm", "fit-hidden.ppm", "fit-shown.png", "fit-hidden.png"):
            sidecar.record_capture(frames, os.path.join(frames, image))
        write_bundle_record(frames)
        return frames

    def write_gpui_sidecar(self, frames, declared_value="synthetic"):
        return sidecar.main(["--frames", frames, "--capture", "gpui", "--window", "8,5",
                             "--states", "fit", "--isonim-tree", self.isonim,
                             "--render-serve-tree", self.serve, "--examples-tree", self.examples])

    def read_sidecar(self, frames, name="fit.sidecar.json"):
        with open(os.path.join(frames, name)) as f:
            return json.load(f)

    def web_run(self, name, page_png=b"page-run", frame_png=b"frame-run", visible=None):
        """A web fit capture run: PNGs written and their digests recorded in web-fit.json, as web_capture.mjs does."""
        frames = self.new_dir(name)
        visible = visible or {"x": 10.4, "y": 20.6, "w": 300, "h": 200}
        write_bytes(os.path.join(frames, "web-fit-page.png"), page_png)
        captures = {"page": {"file": "web-fit-page.png", "sha256": sha(page_png),
                             "capturedAt": "2026-11-11T13:00:00Z", "bytes": len(page_png)}}
        if visible["w"] > 0 and visible["h"] > 0:
            write_bytes(os.path.join(frames, "web-fit-frame.png"), frame_png)
            captures["frame"] = {"file": "web-fit-frame.png", "sha256": sha(frame_png),
                                 "capturedAt": "2026-11-11T13:00:01Z", "bytes": len(frame_png)}
        measured = {"viewport": [1920, 1200], "readout": "fit", "visible": visible,
                    "runId": name, "captures": captures}
        with open(os.path.join(frames, "web-fit.json"), "w") as f:
            json.dump(measured, f)
        write_bundle_record(frames)
        return frames

    def write_web_sidecar(self, frames):
        return sidecar.main(["--frames", frames, "--capture", "web", "--states", "fit",
                             "--isonim-tree", self.isonim, "--render-serve-tree", self.serve,
                             "--examples-tree", self.examples])


class WriteTest(CaptureFixtures):
    def test_gpui_sidecar_written_by_main(self):
        frames = self.gpui_run("gpui", declared_value="synthetic")
        rc = self.write_gpui_sidecar(frames)
        self.assertEqual(rc, 0)
        side = self.read_sidecar(frames)
        self.assertEqual(side["frameSource"], "synthetic")
        self.assertEqual(side["renderer"], "synthetic raster")
        self.assertEqual(side["window"], {"width": 8, "height": 5})
        self.assertEqual(side["paintedBox"], {"x": 4, "y": 0, "width": 4, "height": 5})
        self.assertEqual(side["commits"]["isonim"]["dirtyEntries"], 1)
        self.assertEqual(side["commits"]["renderServe"]["dirtyEntries"], 0)
        self.assertEqual(side["commits"]["examples"]["sha"],
                         subprocess.run(["git", "-C", self.examples, "rev-parse", "HEAD"],
                                        capture_output=True, text=True).stdout.strip())
        self.assertEqual(side["capturedPpm"], {"width": 8, "height": 5})
        self.assertEqual(side["files"]["shownPng"]["sha256"], sha(b"shown-run"))
        self.assertTrue(side["files"]["shownPng"]["capturedAt"].endswith("Z"))

    def test_real_declaration_flows_end_to_end(self):
        side = self.read_sidecar(self._declared("real"))
        self.assertEqual(side["frameSource"], "real")
        self.assertEqual(side["renderer"], "gpui headless")

    def test_absent_declaration_is_none_end_to_end(self):
        frames = self.gpui_run("none", declared_value=None)
        self.write_gpui_sidecar(frames)
        side = self.read_sidecar(frames)
        self.assertEqual(side["frameSource"], "none")
        self.assertEqual(side["renderer"], "gpui (no declared source)")

    def test_source_is_read_from_the_page_not_fixed(self):
        # Two different declarations must give two different sidecars.
        a = self.read_sidecar(self._declared("synthetic"))
        b = self.read_sidecar(self._declared("real"))
        self.assertNotEqual(a["frameSource"], b["frameSource"])

    def _declared(self, value):
        frames = self.gpui_run("declared-" + value, declared_value=value)
        self.write_gpui_sidecar(frames)
        return frames

    def test_web_sidecar_has_no_stream_source(self):
        frames = self.web_run("web")
        rc = self.write_web_sidecar(frames)
        self.assertEqual(rc, 0)
        side = self.read_sidecar(frames, "web-fit.sidecar.json")
        self.assertEqual(side["frameSource"], "none")
        self.assertEqual(side["renderer"], "web iframe")
        self.assertEqual(side["window"], {"width": 1920, "height": 1200})
        self.assertEqual(side["paintedBox"], {"x": 10, "y": 21, "width": 300, "height": 200})
        self.assertEqual(side["files"]["frame"]["sha256"], sha(b"frame-run"))
        self.assertEqual(side["runId"], "web")


class FreshnessTest(CaptureFixtures):
    """The writer describes only images taken in the run it is writing."""

    def test_fresh_gpui_images_are_accepted(self):
        frames = self.gpui_run("fresh")
        self.assertEqual(self.write_gpui_sidecar(frames), 0)
        self.assertTrue(os.path.exists(os.path.join(frames, "fit.sidecar.json")))

    def test_gpui_image_copied_from_an_older_run_is_refused(self):
        older = self.gpui_run("older", shown_png=b"OLD shown")
        newer = self.gpui_run("newer", shown_png=b"NEW shown")
        # The run's own capture record says NEW; the copy from the older run is OLD.
        shutil.copyfile(os.path.join(older, "fit-shown.png"), os.path.join(newer, "fit-shown.png"))
        with self.assertRaises(sidecar.CaptureRefused) as refusal:
            self.write_gpui_sidecar(newer)
        self.assertIn("differs", str(refusal.exception))
        self.assertFalse(os.path.exists(os.path.join(newer, "fit.sidecar.json")))

    def test_gpui_image_changed_after_capture_is_refused(self):
        frames = self.gpui_run("changed")
        write_bytes(os.path.join(frames, "fit-hidden.png"), b"EDITED after capture")
        with self.assertRaises(sidecar.CaptureRefused):
            self.write_gpui_sidecar(frames)
        self.assertFalse(os.path.exists(os.path.join(frames, "fit.sidecar.json")))

    def test_gpui_ppm_changed_after_capture_is_refused(self):
        # The painted box is read from the PPMs, so a changed PPM must not reach it.
        frames = self.gpui_run("ppm-changed")
        write_ppm(os.path.join(frames, "fit-shown.ppm"), 8, 5, lambda x, y: (1, 1, 1))
        with self.assertRaises(sidecar.CaptureRefused):
            self.write_gpui_sidecar(frames)

    def test_gpui_missing_image_is_refused(self):
        frames = self.gpui_run("missing")
        os.remove(os.path.join(frames, "fit-shown.png"))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "image missing"):
            self.write_gpui_sidecar(frames)

    def test_gpui_image_without_a_capture_record_is_refused(self):
        frames = self.new_dir("unrecorded")
        # Only the PPMs were recorded; the PNGs were written without a record.
        measured = {"areaWidth": 8, "readout": "100%", "frameSource": "synthetic"}
        with open(os.path.join(frames, "fit.json"), "w") as f:
            json.dump(measured, f)
        write_ppm(os.path.join(frames, "fit-shown.ppm"), 8, 5, lambda x, y: (200, 200, 200) if x >= 4 else (1, 1, 1))
        write_ppm(os.path.join(frames, "fit-hidden.ppm"), 8, 5, lambda x, y: (1, 1, 1))
        write_bytes(os.path.join(frames, "fit-shown.png"), b"shown")
        write_bytes(os.path.join(frames, "fit-hidden.png"), b"hidden")
        for ppm in ("fit-shown.ppm", "fit-hidden.ppm"):
            sidecar.record_capture(frames, os.path.join(frames, ppm))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "no digest was recorded"):
            self.write_gpui_sidecar(frames)

    def test_record_refuses_to_re_record_a_changed_image(self):
        frames = self.gpui_run("rerecord")
        write_bytes(os.path.join(frames, "fit-shown.png"), b"changed")
        with self.assertRaisesRegex(sidecar.CaptureRefused, "refusing to re-record"):
            sidecar.record_capture(frames, os.path.join(frames, "fit-shown.png"))

    def test_fresh_web_images_are_accepted(self):
        frames = self.web_run("web-fresh")
        self.assertEqual(self.write_web_sidecar(frames), 0)

    def test_web_image_copied_from_an_older_run_is_refused(self):
        older = self.web_run("web-older", page_png=b"OLD page")
        newer = self.web_run("web-newer", page_png=b"NEW page")
        shutil.copyfile(os.path.join(older, "web-fit-page.png"), os.path.join(newer, "web-fit-page.png"))
        with self.assertRaises(sidecar.CaptureRefused):
            self.write_web_sidecar(newer)
        self.assertFalse(os.path.exists(os.path.join(newer, "web-fit.sidecar.json")))

    def test_web_frame_missing_when_visible_is_refused(self):
        frames = self.web_run("web-no-frame")
        os.remove(os.path.join(frames, "web-fit-frame.png"))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "image missing"):
            self.write_web_sidecar(frames)

    def test_web_run_without_a_visible_frame_needs_only_the_page(self):
        frames = self.web_run("web-hidden", visible={"x": 0, "y": 0, "w": 0, "h": 0})
        self.assertEqual(self.write_web_sidecar(frames), 0)
        side = self.read_sidecar(frames, "web-fit.sidecar.json")
        self.assertEqual(sorted(side["files"]), ["page"])


class FrameBoxTest(CaptureFixtures):
    """A shown capture must show a streamed frame in its frame box, not the measuring colour or a blank."""

    def setUp(self):
        super().setUp()
        # One sample per pixel, so the fixtures' small boxes are sampled in full.
        saved = sidecar.SAMPLE_STEP
        sidecar.SAMPLE_STEP = 1
        self.addCleanup(setattr, sidecar, "SAMPLE_STEP", saved)

    def run_with_shown(self, frame_pixel):
        """A fit run whose shown frame area is frame_pixel(x, y) and whose hidden capture is all (1, 1, 1)."""
        frames = self.new_dir("box")
        with open(os.path.join(frames, "fit.json"), "w") as f:
            json.dump({"areaWidth": 8, "readout": "100%", "frameSource": "synthetic"}, f)
        write_ppm(os.path.join(frames, "fit-shown.ppm"), 8, 5,
                  lambda x, y: frame_pixel(x, y) if x >= 4 else (1, 1, 1))
        write_ppm(os.path.join(frames, "fit-hidden.ppm"), 8, 5, lambda x, y: (1, 1, 1))
        write_bytes(os.path.join(frames, "fit-shown.png"), b"shown")
        write_bytes(os.path.join(frames, "fit-hidden.png"), b"hidden")
        for image in ("fit-shown.ppm", "fit-hidden.ppm", "fit-shown.png", "fit-hidden.png"):
            sidecar.record_capture(frames, os.path.join(frames, image))
        write_bundle_record(frames)
        return frames

    def test_magenta_frame_is_refused(self):
        frames = self.run_with_shown(lambda x, y: (255, 0, 255))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "dominant colour is the measuring colour"):
            self.write_gpui_sidecar(frames)
        self.assertFalse(os.path.exists(os.path.join(frames, "fit.sidecar.json")))

    def test_frame_mostly_magenta_is_refused(self):
        # Four of five rows are magenta: the dominant colour is still the measuring colour.
        frames = self.run_with_shown(lambda x, y: (255, 0, 255) if y < 4 else (120, 120, 120))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "measuring colour"):
            self.write_gpui_sidecar(frames)

    def test_uniform_frame_is_refused(self):
        frames = self.run_with_shown(lambda x, y: (200, 200, 200))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "uniform"):
            self.write_gpui_sidecar(frames)

    def test_frame_identical_to_the_hidden_capture_is_refused(self):
        # Shown equals hidden everywhere: nothing painted the frame area.
        frames = self.run_with_shown(lambda x, y: (1, 1, 1))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "no frame was painted"):
            self.write_gpui_sidecar(frames)

    def test_painted_frame_is_accepted_and_its_colours_recorded(self):
        # Three of five rows are one colour and two rows another: a painted frame.
        frames = self.run_with_shown(lambda x, y: (200, 200, 200) if y < 3 else (100, 100, 100))
        self.assertEqual(self.write_gpui_sidecar(frames), 0)
        side = self.read_sidecar(frames)
        self.assertEqual(side["frameBox"]["box"], {"x": 4, "y": 0, "width": 4, "height": 5})
        self.assertEqual(side["frameBox"]["dominant"], "#c8c8c8")
        self.assertEqual(side["frameBox"]["dominantFraction"], 0.6)
        self.assertEqual(side["frameBox"]["distinct"], 2)

    def test_painted_frame_with_default_sampling_is_accepted(self):
        sidecar.SAMPLE_STEP = 3
        frames = self.run_with_shown(lambda x, y: (200, 200, 200) if y < 3 else (100, 100, 100))
        self.assertEqual(self.write_gpui_sidecar(frames), 0)


class BundleTest(unittest.TestCase):
    """editor_bundle.py against a real HTTP server on a free port, serving real build directories."""

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tree = os.path.join(self.tmp.name, "isonim")
        os.makedirs(self.tree)
        git(self.tree, "init", "-q")
        with open(os.path.join(self.tree, "f.txt"), "w") as f:
            f.write("tree")
        git(self.tree, "add", "f.txt")
        git(self.tree, "commit", "-q", "-m", "fixture")
        self.head = subprocess.run(["git", "-C", self.tree, "rev-parse", "HEAD"],
                                   capture_output=True, text=True, check=True).stdout.strip()
        self.build = self.make_build("build", b"bundle A")

    def make_build(self, name, script):
        path = os.path.join(self.tmp.name, name)
        os.makedirs(path)
        write_bytes(os.path.join(path, "index.html"), b"<!doctype html><title>editor</title>")
        write_bytes(os.path.join(path, "editor.js"), script * 10)
        return path

    def serve(self, directory):
        """Starts an HTTP server on a free port for directory and returns its base URL."""
        handler = functools.partial(self.Quiet, directory=directory)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return "http://127.0.0.1:%d/index.html?view=page" % server.server_address[1]

    def test_server_on_this_build_is_accepted(self):
        base = self.serve(self.build)
        record = editor_bundle.check(base, self.build, self.tree)
        self.assertEqual(record["files"]["editor.js"]["servedSha256"], sha(b"bundle A" * 10))
        self.assertEqual(record["files"]["editor.js"]["buildSha256"], sha(b"bundle A" * 10))
        self.assertEqual(record["treeHead"], self.head)
        self.assertEqual(record["url"], base.split("/index.html")[0])

    def test_server_on_an_older_build_directory_is_refused(self):
        older = self.make_build("older", b"bundle old")
        base = self.serve(older)
        with self.assertRaisesRegex(editor_bundle.CaptureRefused, "not serving this build directory"):
            editor_bundle.check(base, self.build, self.tree)

    def test_build_older_than_head_commit_is_refused(self):
        base = self.serve(self.build)
        commit_time = int(subprocess.run(["git", "-C", self.tree, "log", "-1", "--format=%ct"],
                                         capture_output=True, text=True, check=True).stdout)
        old = commit_time - 3600
        os.utime(os.path.join(self.build, "editor.js"), (old, old))
        with self.assertRaisesRegex(editor_bundle.CaptureRefused, "predates"):
            editor_bundle.check(base, self.build, self.tree)

    def test_no_server_is_refused(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with self.assertRaisesRegex(editor_bundle.CaptureRefused, "no editor server answered"):
            editor_bundle.check("http://127.0.0.1:%d/index.html" % port, self.build, self.tree)

    def test_main_writes_the_record(self):
        base = self.serve(self.build)
        out = os.path.join(self.tmp.name, "bundle.json")
        with redirect_stdout(io.StringIO()):
            rc = editor_bundle.main(["--base", base, "--build", self.build, "--tree", self.tree, "--out", out])
        self.assertEqual(rc, 0)
        with open(out) as f:
            self.assertEqual(json.load(f)["treeHead"], self.head)


class BundleRecordInSidecarTest(CaptureFixtures):
    def test_run_without_a_bundle_record_is_refused(self):
        frames = self.gpui_run("no-bundle")
        os.remove(os.path.join(frames, sidecar.BUNDLE_FILE))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "bundle.json missing"):
            self.write_gpui_sidecar(frames)

    def test_web_run_without_a_bundle_record_is_refused(self):
        frames = self.web_run("web-no-bundle")
        os.remove(os.path.join(frames, sidecar.BUNDLE_FILE))
        with self.assertRaisesRegex(sidecar.CaptureRefused, "bundle.json missing"):
            self.write_web_sidecar(frames)


if __name__ == "__main__":
    unittest.main()
