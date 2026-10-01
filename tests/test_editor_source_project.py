#!/usr/bin/env python3
"""Actual native CLI dispatcher, workspace adapter, filesystem and Nim compiler.

No fake compiler, dispatcher or filesystem boundaries. A scheduling barrier
wraps the actual producer solely to test interrupted transactions deterministically;
it preserves the real compiler call after release. The small checked-in
consumer is copied into a disposable project so writes cannot alter live sites.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import time
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
BINARY = REPO / "build/bin/isonim"

class NativeSourceProject(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="isonim-native-source-")
        self.root = Path(self.temporary.name) / "project"
        shutil.copytree(REPO / "examples/source_project", self.root,
            ignore=shutil.ignore_patterns("catalog-producer*", "catalog.json"))
        self.env = {**os.environ, "ISONIM_SOURCE_FRAMEWORK": str(REPO)}
        subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.root)],
            env=self.env, check=True, capture_output=True, timeout=120)

    def tearDown(self):
        self.temporary.cleanup()

    def invoke(self, request, expected=0):
        payload = self.root / "request.json"
        payload.write_text(json.dumps(request))
        result = subprocess.run([str(BINARY), "source-project", str(self.root), str(payload)],
            env=self.env, text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_real_compilation_publication_failure_preserves_general_edit_and_catalog(self):
        source_path = self.root / "stories.nim"
        edited = source_path.read_text().replace("Ready card", "Publication pending actual title")
        source_path.write_text(edited)
        catalog_path = self.root / ".isonim/catalog.json"
        before = catalog_path.read_bytes()
        manifest_path = self.root / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        # Actual producer runs before a real filesystem permission failure. The
        # saved stdout proves compiled/rendered new source, rather than a fake ACK.
        (self.root / "publication_failure.py").write_text(
            "from pathlib import Path\nimport os,subprocess,sys\n"
            "run=subprocess.run(['python3','build_catalog.py'],capture_output=True,text=True)\n"
            "if run.returncode: sys.stdout.write(run.stdout); sys.exit(run.returncode)\n"
            "Path('actually-compiled.json').write_text(run.stdout)\n"
            "os.chmod('.isonim',0o555)\nsys.stdout.write(run.stdout)\n")
        manifest["build"] = ["python3", "publication_failure.py"]
        manifest_path.write_text(json.dumps(manifest))
        try:
            failed = self.invoke({"command": "build"}, 4)
            self.assertFalse(failed["ok"])
            self.assertEqual(failed["stage"], "wesFailed")
            self.assertIn("Catalog publication failed", failed["diagnostic"])
            self.assertIn("Permission denied", failed["diagnostic"])
            compiled = json.loads((self.root / "actually-compiled.json").read_text())
            self.assertIn("Publication pending actual title", compiled["stories"][0]["documentHtml"])
            self.assertEqual(catalog_path.read_bytes(), before)
            self.assertEqual(source_path.read_text(), edited)
            self.assertFalse((self.root / ".isonim/source-transaction.json").exists())
        finally:
            (self.root / ".isonim").chmod(0o755)
        manifest["build"] = ["python3", "build_catalog.py"]
        manifest_path.write_text(json.dumps(manifest))
        recovered = self.invoke({"command": "build"})
        self.assertTrue(recovered["ok"])
        self.assertEqual(json.loads(catalog_path.read_text()), recovered["catalog"])
        self.assertIn("Publication pending actual title", catalog_path.read_text())

    def test_create_persists_compiles_renders_and_reloads(self):
        before = (self.root / "stories.nim").read_text()
        result = self.invoke({"command":"create-story", "component":"Card", "variantKey":"default", "stateKey":"busy"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["storyId"], "Card / default busy")
        source = (self.root / "stories.nim").read_text()
        self.assertNotEqual(source, before)
        self.assertIn('card("Busy card")', source)
        catalog = json.loads((self.root / ".isonim/catalog.json").read_text())
        rows = [row for row in catalog["stories"] if row["name"] == "default busy"]
        self.assertEqual(len(rows), 1)
        self.assertIn("<h1>Busy card</h1>", rows[0]["documentHtml"])
        reloaded = self.invoke({"command":"build"})
        self.assertEqual(reloaded["catalog"], catalog)
        duplicate = self.invoke({"command":"create-story", "component":"Card", "variantKey":"default", "stateKey":"busy"}, 4)
        self.assertFalse(duplicate["ok"])
        self.assertEqual((self.root / "stories.nim").read_text(), source)

    def test_successful_compiler_cannot_report_creation_without_published_story(self):
        source_path = self.root / "stories.nim"
        source = source_path.read_text().replace('echo $(%* {"stories": stories})', 'stories = %*[stories[0]]\necho $(%* {"stories": stories})')
        source_path.write_text(source)
        catalog = (self.root / ".isonim/catalog.json").read_bytes()
        failed = self.invoke({"command":"create-story", "component":"Card", "variantKey":"default", "stateKey":"busy"}, 4)
        self.assertFalse(failed["ok"])
        self.assertIn("Compiled catalog omits requested story: Card / default busy", failed["diagnostic"])
        self.assertEqual(source_path.read_text(), source)
        self.assertEqual((self.root / ".isonim/catalog.json").read_bytes(), catalog)
        self.assertEqual(failed["variants"][0]["stateControls"][0]["story"]["name"], "")
        self.assertEqual(failed["pendingEdits"], [])

    def test_actual_compile_failure_rolls_back_created_source_and_preserves_catalog(self):
        source = (self.root / "stories.nim").read_text()
        catalog = (self.root / ".isonim/catalog.json").read_bytes()
        manifest_path = self.root / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["fixtures"][0]["declaration"] += "\nlet actualCompilerMustReject: int = \"wrong type\""
        manifest_path.write_text(json.dumps(manifest))
        failed = self.invoke({"command":"create-story", "component":"Card", "variantKey":"default", "stateKey":"busy"}, 4)
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["variants"][0]["stateControls"][0]["story"]["name"], "")
        self.assertEqual(failed["pendingEdits"], [])
        self.assertIn("type mismatch", failed["diagnostic"])
        self.assertIn("stories.nim", failed["diagnostic"])
        self.assertEqual((self.root / "stories.nim").read_text(), source)
        self.assertEqual((self.root / ".isonim/catalog.json").read_bytes(), catalog)

    def test_normal_source_edits_build_new_catalog_and_invalid_edit_preserves_previous_output(self):
        source_path = self.root / "stories.nim"
        source = source_path.read_text().replace("Ready card", "Agent edited title")
        source_path.write_text(source)
        rebuilt = self.invoke({"command":"build"})
        self.assertIn("Agent edited title", rebuilt["catalog"]["stories"][0]["documentHtml"])
        catalog = (self.root / ".isonim/catalog.json").read_bytes()
        source_path.write_text(source + '\nlet broken: int = "wrong"\n')
        failed = self.invoke({"command":"build"}, 4)
        self.assertIn("type mismatch", failed["diagnostic"])
        self.assertEqual((self.root / ".isonim/catalog.json").read_bytes(), catalog)

    def interrupted_fixture(self, intervening_edit=False):
        manifest_path = self.root / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        started = self.root / "producer-started"
        barrier = self.root / "release-producer"
        wrapper = self.root / "barrier.py"
        wrapper.write_text('from pathlib import Path\nimport subprocess,time,sys\n' +
            'Path("producer-started").write_text("started")\n' +
            'while not Path("release-producer").exists(): time.sleep(.02)\n' +
            'sys.exit(subprocess.call(["python3","build_catalog.py"]))\n')
        manifest["build"] = ["python3", "barrier.py"]
        manifest_path.write_text(json.dumps(manifest))
        source_path = self.root / "stories.nim"
        original = source_path.read_text()
        catalog = (self.root / ".isonim/catalog.json").read_bytes()
        payload = self.root / "request.json"
        payload.write_text(json.dumps({"command":"create-story", "component":"Card", "variantKey":"default", "stateKey":"busy"}))
        process = subprocess.Popen([str(BINARY), "source-project", str(self.root), str(payload)],
            env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(started.exists(), "Actual producer reached the barrier after persisted fixture write")
            self.assertIn('card("Busy card")', source_path.read_text())
            if intervening_edit:
                source_path.write_text(source_path.read_text() + "\n# Human edit while compiling\n")
            latest = source_path.read_text()
        finally:
            if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
        recovered = self.invoke_recovery(4 if intervening_edit else 0)
        self.assertEqual((self.root / ".isonim/catalog.json").read_bytes(), catalog)
        if intervening_edit:
            self.assertIn("conflicts with a later edit", recovered["diagnostic"])
            self.assertEqual(source_path.read_text(), latest)
            self.assertTrue((self.root / ".isonim/source-transaction.json").exists())
        else:
            self.assertEqual(source_path.read_text(), original)
            self.assertFalse((self.root / ".isonim/source-transaction.json").exists())

    def invoke_recovery(self, expected):
        process = subprocess.run([str(BINARY), "source-project", str(self.root), "--recover"],
            env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(process.returncode, expected, process.stdout + process.stderr)
        return json.loads(process.stdout)

    def test_interrupted_real_worker_restores_uncommitted_fixture(self):
        self.interrupted_fixture()

    def test_interrupted_transaction_never_overwrites_later_human_edit(self):
        self.interrupted_fixture(intervening_edit=True)

    def test_schema_path_escape_and_unknown_fixture_do_not_write(self):
        source = (self.root / "stories.nim").read_bytes()
        failed = self.invoke({"command":"create-story", "component":"Missing", "variantKey":"default", "stateKey":"busy"}, 4)
        self.assertIn("Unknown component", failed["diagnostic"])
        manifest_path = self.root / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["fixtures"][0]["file"] = "../outside.nim"
        manifest_path.write_text(json.dumps(manifest))
        failed = self.invoke({"command":"create-story", "component":"Card", "variantKey":"default", "stateKey":"busy"}, 4)
        self.assertIn("escapes workspace", failed["diagnostic"])
        self.assertEqual((self.root / "stories.nim").read_bytes(), source)
        self.assertFalse((self.root.parent / "outside.nim").exists())

if __name__ == "__main__":
    unittest.main()
