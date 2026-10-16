#!/usr/bin/env python3
"""Actual native CLI dispatcher, workspace adapter, filesystem and Nim compiler.

No fake compiler, dispatcher or filesystem boundaries. A scheduling barrier
wraps the actual producer solely to test interrupted transactions deterministically;
it preserves the real compiler call after release. The concurrent-cache control
uses an argv-recording rendezvous launcher which execs the real Nim compiler
once, without substituting compiler results; this coordinates both genuine
compiler launches and exposes their actual cache arguments. The small checked-in
consumer is copied into a disposable project so writes cannot alter live sites.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time
import subprocess
import tempfile
import unittest
import concurrent.futures

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


class ConcurrentCatalogCaches(unittest.TestCase):
    def test_real_missing_compiler_exception_removes_invocation_cache(self):
        with tempfile.TemporaryDirectory(prefix="isonim-missing-compiler-") as temporary:
            area = Path(temporary)
            project = area / "project"
            shutil.copytree(REPO / "examples/source_project", project,
                ignore=shutil.ignore_patterns("catalog-producer*", "catalog.json", "catalog-nimcache-*"))
            record = area / "attempt.json"
            # Python's audit hook observes the real subprocess launch; it never
            # replaces execution. An empty PATH causes genuine exec failure.
            script = """import json, pathlib, runpy, sys
record = pathlib.Path(sys.argv[1])
def observe(event, args):
    if event == 'subprocess.Popen':
        caches = [x.split(':', 1)[1] for x in args[1] if x.startswith('--nimcache:')]
        cache = pathlib.Path(caches[0])
        record.write_text(json.dumps({'cache': str(cache), 'exists': cache.is_dir()}))
sys.addaudithook(observe)
runpy.run_path(sys.argv[2], run_name='__main__')
"""
            result = subprocess.run([sys.executable, "-c", script, str(record), str(project / "build_catalog.py")],
                env={**os.environ, "PATH": "", "ISONIM_SOURCE_FRAMEWORK": str(REPO)},
                capture_output=True, text=True, timeout=120)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FileNotFoundError", result.stderr)
            observed = json.loads(record.read_text())
            self.assertTrue(observed["exists"], "Actual invocation cache existed before failed exec")
            self.assertEqual(Path(observed["cache"]).parent, project / ".isonim")
            self.assertFalse(Path(observed["cache"]).exists())

    def test_real_concurrent_projects_use_private_invocation_caches(self):
        real_nim = shutil.which("nim")
        self.assertIsNotNone(real_nim, "The owning environment must supply real Nim")
        with tempfile.TemporaryDirectory(prefix="isonim-concurrent-catalog-") as temporary:
            area = Path(temporary)
            launcher = area / "bin"
            launcher.mkdir()
            # Both genuine compilers must arrive before either execs. Recording
            # is private test instrumentation; stdout stays real catalog JSON.
            (launcher / "nim").write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys, time
area = pathlib.Path(os.environ['CACHE_TEST_AREA'])
name = os.environ['CACHE_TEST_RUN']
args = sys.argv[1:]
caches = [x.split(':', 1)[1] for x in args if x.startswith('--nimcache:')]
cache = pathlib.Path(caches[0]) if len(caches) == 1 else None
record = {'argv': args, 'cache': str(cache) if cache else None,
          'cacheExists': cache.is_dir() if cache else False,
          'mode': (cache.stat().st_mode & 0o777) if cache else None,
          'compiler': os.environ['CACHE_TEST_NIM'], 'pid': os.getpid()}
(area / (name + '.json')).write_text(json.dumps(record))
if os.environ.get('CACHE_TEST_PAIR'):
    until = time.monotonic() + 30
    while not all((area / (x + '.json')).exists() for x in ('alpha', 'beta')):
        if time.monotonic() >= until: raise RuntimeError('Other real compiler did not arrive')
        time.sleep(0.005)
os.execv(os.environ['CACHE_TEST_NIM'], [os.environ['CACHE_TEST_NIM'], *args])
""")
            (launcher / "nim").chmod(0o755)
            projects = {}
            for name in ("alpha", "beta"):
                project = area / name
                shutil.copytree(REPO / "examples/source_project", project,
                    ignore=shutil.ignore_patterns("catalog-producer*", "catalog.json", "catalog-nimcache-*"))
                source = project / "stories.nim"
                source.write_text(source.read_text().replace("Ready card", "CACHE_" + name.upper()))
                projects[name] = project

            def compile_project(name, project, paired=False):
                env = {**os.environ, "ISONIM_SOURCE_FRAMEWORK": str(REPO),
                    "PATH": str(launcher) + os.pathsep + os.environ["PATH"],
                    "CACHE_TEST_AREA": str(area), "CACHE_TEST_RUN": name,
                    "CACHE_TEST_NIM": real_nim}
                if paired:
                    env["CACHE_TEST_PAIR"] = "1"
                else:
                    env.pop("CACHE_TEST_PAIR", None)
                return subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(project)],
                    env=env, text=True, capture_output=True, timeout=120)

            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                pending = {name: pool.submit(compile_project, name, project, True)
                           for name, project in projects.items()}
                results = {name: future.result() for name, future in pending.items()}
            records = []
            for name, result in results.items():
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                catalog = json.loads((projects[name] / ".isonim/catalog.json").read_text())
                self.assertIn("CACHE_" + name.upper(), catalog["stories"][0]["documentHtml"])
                other = "beta" if name == "alpha" else "alpha"
                self.assertNotIn("CACHE_" + other.upper(), json.dumps(catalog))
                self.assertEqual(json.loads((projects[name] / ".isonim/catalog.json").read_text()), catalog)
                records.append(json.loads((area / (name + ".json")).read_text()))
            # A fixed per-project cache would pass only the two-project control;
            # repeat the same project to require per-invocation isolation too.
            repeat = compile_project("repeat", projects["alpha"])
            self.assertEqual(repeat.returncode, 0, repeat.stdout + repeat.stderr)
            records.append(json.loads((area / "repeat.json").read_text()))
            catalog_before = (projects["alpha"] / ".isonim/catalog.json").read_bytes()
            with (projects["alpha"] / "stories.nim").open("a") as source:
                source.write('\nlet cacheFailure: int = "actual type error"\n')
            failure = compile_project("failure", projects["alpha"])
            self.assertNotEqual(failure.returncode, 0)
            self.assertIn("type mismatch", failure.stdout + failure.stderr)
            self.assertEqual((projects["alpha"] / ".isonim/catalog.json").read_bytes(), catalog_before)
            records.append(json.loads((area / "failure.json").read_text()))
            self.assertEqual(len({record["cache"] for record in records}), 4)
            self.assertNotEqual(records[0]["pid"], records[1]["pid"])
            for index, record in enumerate(records):
                self.assertEqual(record["compiler"], real_nim)
                self.assertTrue(record["cacheExists"])
                self.assertEqual(record["mode"], 0o700)
                project = projects["beta"] if index == 1 else projects["alpha"]
                self.assertEqual(Path(record["cache"]).parent, project / ".isonim")
                self.assertFalse(Path(record["cache"]).exists(), "Invocation cache must be removed")
            evidence = os.environ.get("ISONIM_CACHE_TEST_EVIDENCE")
            if evidence:
                Path(evidence).write_text(json.dumps({"records": records,
                    "returncodes": {**{k: v.returncode for k, v in results.items()},
                                    "repeat": repeat.returncode, "failure": failure.returncode},
                    "catalogs": {k: json.loads((projects[k] / ".isonim/catalog.json").read_text()) for k in results}}, indent=2))

if __name__ == "__main__":
    unittest.main()
