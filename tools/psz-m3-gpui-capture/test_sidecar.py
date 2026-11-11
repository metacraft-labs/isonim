"""Fixture tests for sidecar.py: the painted box, the frame source, and a full write.

These need no browser, no sway and no editor server. Each test builds its own
PPM and JSON fixtures in a temporary directory, and a temporary git checkout for
the commit fields, so the result depends only on this file and sidecar.py.
Run: python3 -m unittest -v test_sidecar.py   (from this directory)
"""
import json
import os
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


class WriteTest(unittest.TestCase):
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

    def tearDown(self):
        self.tmp.cleanup()

    def trees(self):
        return {"isonim": self.isonim, "renderServe": self.serve, "examples": self.examples}

    def test_gpui_sidecar_written_by_main(self):
        frames = os.path.join(self.root, "frames")
        os.makedirs(frames)
        measured = {"frameSource": "synthetic", "areaWidth": 1340, "readout": "100%",
                    "frameSourceLabel": {"present": True, "visible": True, "text": "synthetic"}}
        with open(os.path.join(frames, "fit.json"), "w") as f:
            json.dump(measured, f)
        write_ppm(os.path.join(frames, "fit-shown.ppm"), 8, 5, lambda x, y: (200, 200, 200) if x >= 4 else (1, 1, 1))
        write_ppm(os.path.join(frames, "fit-hidden.ppm"), 8, 5, lambda x, y: (1, 1, 1))
        rc = sidecar.main(["--frames", frames, "--capture", "gpui", "--window", "8,5",
                           "--states", "fit", "--isonim-tree", self.isonim,
                           "--render-serve-tree", self.serve, "--examples-tree", self.examples])
        self.assertEqual(rc, 0)
        with open(os.path.join(frames, "fit.sidecar.json")) as f:
            side = json.load(f)
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

    def _gpui_with_declaration(self, declared_value, name):
        """Writes a GPUI state whose page declares declared_value, runs main, returns the sidecar."""
        frames = os.path.join(self.root, name)
        os.makedirs(frames)
        measured = {"areaWidth": 8, "readout": "100%"}
        if declared_value is not None:
            measured["frameSource"] = declared_value
        with open(os.path.join(frames, "fit.json"), "w") as f:
            json.dump(measured, f)
        write_ppm(os.path.join(frames, "fit-shown.ppm"), 8, 5, lambda x, y: (200, 200, 200) if x >= 4 else (1, 1, 1))
        write_ppm(os.path.join(frames, "fit-hidden.ppm"), 8, 5, lambda x, y: (1, 1, 1))
        sidecar.main(["--frames", frames, "--capture", "gpui", "--window", "8,5",
                      "--states", "fit", "--isonim-tree", self.isonim,
                      "--render-serve-tree", self.serve, "--examples-tree", self.examples])
        with open(os.path.join(frames, "fit.sidecar.json")) as f:
            return json.load(f)

    def test_real_declaration_flows_end_to_end(self):
        side = self._gpui_with_declaration("real", "frames-real")
        self.assertEqual(side["frameSource"], "real")
        self.assertEqual(side["renderer"], "gpui headless")

    def test_absent_declaration_is_none_end_to_end(self):
        side = self._gpui_with_declaration(None, "frames-none")
        self.assertEqual(side["frameSource"], "none")
        self.assertEqual(side["renderer"], "gpui (no declared source)")

    def test_source_is_read_from_the_page_not_fixed(self):
        # Two different declarations must give two different sidecars.
        a = self._gpui_with_declaration("synthetic", "frames-a")
        b = self._gpui_with_declaration("real", "frames-b")
        self.assertNotEqual(a["frameSource"], b["frameSource"])

    def test_web_sidecar_has_no_stream_source(self):
        frames = os.path.join(self.root, "frames-web")
        os.makedirs(frames)
        measured = {"viewport": [1920, 1200], "readout": "fit",
                    "visible": {"x": 10.4, "y": 20.6, "w": 300, "h": 200}}
        with open(os.path.join(frames, "web-fit.json"), "w") as f:
            json.dump(measured, f)
        rc = sidecar.main(["--frames", frames, "--capture", "web", "--states", "fit",
                           "--isonim-tree", self.isonim, "--render-serve-tree", self.serve,
                           "--examples-tree", self.examples])
        self.assertEqual(rc, 0)
        with open(os.path.join(frames, "web-fit.sidecar.json")) as f:
            side = json.load(f)
        self.assertEqual(side["frameSource"], "none")
        self.assertEqual(side["renderer"], "web iframe")
        self.assertEqual(side["window"], {"width": 1920, "height": 1200})
        self.assertEqual(side["paintedBox"], {"x": 10, "y": 21, "width": 300, "height": 200})


if __name__ == "__main__":
    unittest.main()
