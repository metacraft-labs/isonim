"""Real project lock, filesystem, native worker, compiler and production HTTP GET.

No source/compiler/HTTP result is mocked. A project-owned timing wrapper gates
BEFORE exec of the unchanged genuine Nim catalog producer, then execs it without
substituting outputs. Direct native writes are invoked under the actual server
source_lock used by POST; this isolates the reviewed journal/metadata boundary,
not daemon authorization or browser ACK. Interruption terminates the entire
native/compiler process group and reaps it before recovery, matching server
shutdown/timeout cleanup; arbitrary parent-only kill with orphan producers is
not covered. Existing authenticated route/source GUI
suites separately own those boundaries. No agent is started or prompted here.
"""
import concurrent.futures
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("isonim_source_server", REPO / "tools/editor_server.py")
server_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_module)

class MetadataTransactionTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="metadata-transaction-", dir=os.environ.get("ISONIM_POPUP_ARTIFACTS")))
        self.project = self.directory / "project"
        shutil.copytree(REPO / "tests/fixtures/editor_inspector_project", self.project)
        self.binary = REPO / "build/bin/isonim-review"
        self.env = {**os.environ, "ISONIM_SOURCE_FRAMEWORK": str(REPO)}
        built = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)], env=self.env,
                               capture_output=True, text=True, timeout=70)
        (self.directory / "initial-build.log").write_text(built.stdout + built.stderr)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        self.source = self.project / "stories.nim"
        self.catalog = self.project / ".isonim/catalog.json"
        self.journal = self.project / ".isonim/source-transaction.json"
        self.original, self.original_catalog = self.source.read_bytes(), self.catalog.read_bytes()
        (self.directory / "source-before.nim").write_bytes(self.original)
        (self.directory / "catalog-before.json").write_bytes(self.original_catalog)
        self.source.chmod(0o640)
        self.catalog.chmod(0o640)
        described = self.invoke("--describe")
        entry = next(row for row in described["editableStyles"] if row["elementId"] == "action")
        self.request = {"command":"inspector-edit", "commandId":"compiler-gated", "expectedRevision":0,
            "schemaKey":entry["key"], "target":entry["elementId"], "storyId":entry["storyId"],
            "property":"width", "value":"240px", "expectedValue":entry["values"]["width"],
            "expectedSourceHash":entry["sourceHash"], "viewportWidth":1440}
        self.payload = self.directory / "request.json"
        self.payload.write_text(json.dumps(self.request))
        manifest_path = self.project / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        self.real_build = manifest["build"]
        (self.project / "compiler_gate.py").write_text(
            "import os,pathlib,time,sys,json\n"
            "p=pathlib.Path(__file__).resolve().parent\n"
            "(p/'compiler-waiting').write_text('genuine compiler gated')\n"
            "while not (p/'compiler-release').exists():time.sleep(.01)\n"
            "command=json.loads((p/'real-build.json').read_text())\n"
            "os.execvp(command[0],command)\n")
        (self.project / "real-build.json").write_text(json.dumps(self.real_build))
        manifest["build"] = ["python3", "compiler_gate.py"]
        manifest_path.write_text(json.dumps(manifest))
        self.process = None

    def invoke(self, argument, expected=0):
        result = subprocess.run([str(self.binary), "source-project", str(self.project), str(argument)], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def start(self):
        self.process = subprocess.Popen([str(self.binary), "source-project", str(self.project), str(self.payload)],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        deadline = time.monotonic() + 10
        while not (self.project / "compiler-waiting").exists():
            self.assertIsNone(self.process.poll(), "Native worker must still be live")
            self.assertLess(time.monotonic(), deadline, "Real compiler must reach its unchanged gate")
            time.sleep(.01)
        self.assertIn(b"width:240px;", self.source.read_bytes())
        self.assertTrue(self.journal.exists())
        (self.directory / "active-source.nim").write_bytes(self.source.read_bytes())
        (self.directory / "active-journal.json").write_bytes(self.journal.read_bytes())
        return self.source.read_bytes(), self.journal.read_bytes(), self.catalog.read_bytes()

    def finish(self):
        (self.project / "compiler-release").touch()
        stdout, stderr = self.process.communicate(timeout=120)
        (self.directory / "native-output.json").write_text(stdout)
        (self.directory / "native-stderr.log").write_text(stderr)
        self.assertEqual(self.process.returncode, 0, stdout + stderr)
        outcome = json.loads(stdout)
        self.assertTrue(outcome["ok"], outcome)
        self.assertIn(b"width:240px;", self.source.read_bytes())
        self.assertIn(b"width:240px;", self.catalog.read_bytes())
        self.assertEqual(json.loads(self.catalog.read_text()), outcome["catalog"])
        self.assertFalse(self.journal.exists())
        (self.directory / "catalog-after.json").write_bytes(self.catalog.read_bytes())
        (self.directory / "source-after.nim").write_bytes(self.source.read_bytes())
        (self.directory / "proof.json").write_text(json.dumps({"test":self.id(),
            "nativeSha256":hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "sourceWidth":"240px", "catalogWidth":"240px", "nativeOk":outcome["ok"],
            "journalPresent":self.journal.exists()}, indent=2))
        return outcome

    def tearDown(self):
        if self.process and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.communicate(timeout=5)

    def test_no_metadata_positive_control_persists_requested_source_and_catalog(self):
        self.start()
        self.finish()

    def test_direct_read_recover_and_second_worker_cannot_recover_live_compiler(self):
        active = self.start()
        for argument in ["--describe", "--snapshot", "--recover", self.payload]:
            with self.subTest(argument=str(argument)):
                result = self.invoke(argument, expected=4)
                self.assertIn("busy", result["diagnostic"])
                self.assertEqual((self.source.read_bytes(), self.journal.read_bytes(), self.catalog.read_bytes()), active)
                self.assertIsNone(self.process.poll())
        self.finish()

    def test_http_metadata_waits_for_complete_transaction_and_returns_new_snapshot(self):
        class Handler(server_module.EditorHandler):
            source_root = self.project
            source_binary = self.binary
            source_lock = threading.Lock()
        server = server_module.EditorHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        lock_owned = False
        try:
            Handler.source_lock.acquire(); lock_owned = True
            active = self.start()
            def metadata():
                with urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}/api/editor/source/catalog", timeout=120) as response:
                    self.assertEqual(response.status, 200)
                    return json.load(response)
            pending = pool.submit(metadata)
            # Read's real HTTP thread must wait; this is a timing barrier only,
            # not a fabricated source result. Snapshot is asserted after release.
            time.sleep(.25)
            self.assertFalse(pending.done(), "Metadata cannot read through the active project boundary")
            self.assertEqual((self.source.read_bytes(), self.journal.read_bytes(), self.catalog.read_bytes()), active)
            outcome = self.finish()
            Handler.source_lock.release(); lock_owned = False
            received = pending.result(timeout=5)
            self.assertEqual(received["catalog"], outcome["catalog"])
            row = next(row for row in received["editableStyles"] if row["elementId"] == "action")
            self.assertEqual(row["values"]["width"], "240px")
            self.assertEqual(row["sourceHash"], next(row for row in outcome["editableStyles"] if row["elementId"] == "action")["sourceHash"])
        finally:
            if lock_owned: Handler.source_lock.release()
            server.shutdown(); server.server_close(); pool.shutdown(wait=True)

    def test_interrupted_writer_read_is_nonmutating_and_explicit_recovery_restores_bytes_and_modes(self):
        active = self.start()
        os.killpg(self.process.pid, signal.SIGKILL)
        self.process.communicate(timeout=5)
        for option in ["--describe", "--snapshot"]:
            result = self.invoke(option, expected=4)
            self.assertIn("requires explicit recovery", result["diagnostic"])
            self.assertEqual((self.source.read_bytes(), self.journal.read_bytes(), self.catalog.read_bytes()), active)
        self.assertTrue(self.invoke("--recover")["ok"])
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.catalog.read_bytes(), self.original_catalog)
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.catalog.stat().st_mode & 0o777, 0o640)
        self.assertFalse(self.journal.exists())
        snapshot = self.invoke("--snapshot")
        self.assertEqual(snapshot["catalog"], json.loads(self.original_catalog))
        self.assertEqual(next(row for row in snapshot["editableStyles"] if row["elementId"] == "action")["values"]["width"], "120px")
        (self.directory / "proof.json").write_text(json.dumps({"test":self.id(),
            "nativeSha256":hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "wholeProcessGroupKilledAndReaped":True,"sourceExact":True,"catalogExact":True,
            "sourceMode":oct(self.source.stat().st_mode & 0o777),"catalogMode":oct(self.catalog.stat().st_mode & 0o777)}, indent=2))

if __name__ == "__main__":
    unittest.main(verbosity=2)
