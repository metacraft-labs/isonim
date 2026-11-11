"""Fixture tests for sidecar.py: the painted box, the frame source, a full write, and freshness.

These need no browser, no sway and no editor server. Each test builds its own
PPM, PNG and JSON fixtures in a temporary directory, and a temporary git checkout
for the commit fields, so the result depends only on this file and sidecar.py.
The fixture PNGs are arbitrary bytes: the writer hashes an image and never
decodes it, so the freshness rules do not depend on a PNG encoder.
Run: python3 -m unittest -v test_sidecar.py   (from this directory)
"""
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest

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
        write_ppm(os.path.join(frames, "fit-shown.ppm"), 8, 5, lambda x, y: (200, 200, 200) if x >= 4 else (1, 1, 1))
        write_ppm(os.path.join(frames, "fit-hidden.ppm"), 8, 5, lambda x, y: (1, 1, 1))
        write_bytes(os.path.join(frames, "fit-shown.png"), shown_png)
        write_bytes(os.path.join(frames, "fit-hidden.png"), hidden_png)
        for image in ("fit-shown.ppm", "fit-hidden.ppm", "fit-shown.png", "fit-hidden.png"):
            sidecar.record_capture(frames, os.path.join(frames, image))
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


if __name__ == "__main__":
    unittest.main()
