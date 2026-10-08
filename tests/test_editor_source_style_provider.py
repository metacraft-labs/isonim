"""Actual GRIP SSR/compiler source-provider integration in a disposable copy.

No renderer, source map, filesystem, worker or compiler is mocked. The existing
prototype is copied read-only and opts into the reusable constant provider only
inside that copy; the protected network instance is never built or modified.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent

class SourceStyleProviderTests(unittest.TestCase):
    def test_real_grip_compiled_targets_shared_scope_and_follow_up_source_edit(self):
        prototype = Path(os.environ.get("ISONIM_SOURCE_PROVIDER_PROJECT", REPO.parent / "web-site-prototypes/grip/isonim"))
        self.assertTrue((prototype / "src/components/styles.nim").is_file(), "Real GRIP source fixture is required.")
        directory = Path(tempfile.mkdtemp(prefix="source-provider-", dir=os.environ.get("ISONIM_POPUP_ARTIFACTS")))
        project = directory / "project"
        shutil.copytree(prototype, project, ignore=shutil.ignore_patterns(".git", ".repro", "build", "node_modules", "catalog-producer"))
        (project / "config.nims").write_text('switch("nimcache", ' + json.dumps(str(project / "native-cache")) + ')\n')
        source = project / "src/components/styles.nim"
        original = source.read_bytes()
        manifest_path = project / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["editableStyleSources"] = [{"file": "src/components/styles.nim", "const": "structureCss",
            "properties": ["font-size", "font-weight", "letter-spacing", "gap", "height", "width", "padding", "border-radius", "color", "background", "opacity"]}]
        manifest_path.write_text(json.dumps(manifest))
        env = {**os.environ, "ISONIM_SOURCE_FRAMEWORK": str(REPO)}
        built = subprocess.run(["python3", "tools/build_editor_catalog.py"], cwd=project,
            env=env, capture_output=True, text=True, timeout=90)
        (directory / "initial-build.log").write_text(built.stdout + built.stderr)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        catalog = json.loads(built.stdout)
        (project / manifest["catalog"]).write_text(json.dumps(catalog))
        binary = REPO / "build/bin/isonim-review"
        described = subprocess.run([str(binary), "source-project", str(project), "--describe"],
            env=env, capture_output=True, text=True, timeout=5)
        (directory / "describe.log").write_text(described.stdout + described.stderr)
        self.assertEqual(described.returncode, 0, described.stdout + described.stderr)
        bindings = json.loads(described.stdout)["editableStyles"]
        panels = [row for row in bindings if row["selector"] == ".panel" and "border-radius" in row["values"]]
        self.assertGreaterEqual(len(panels), 2, "Actual multiple compiled panel targets are required.")
        target = panels[0]
        self.assertEqual(target["scope"], "shared-class")
        self.assertEqual(target["sharedCount"], len(panels))
        self.assertEqual(target["values"]["border-radius"], "4px")
        self.assertEqual(target["sourceHash"], hashlib.sha1(original).hexdigest().upper())
        self.assertFalse(any("var(" in value for row in bindings for value in row["values"].values()), "Token ownership must not become a direct literal writer.")
        self.assertFalse(any("height" in row["values"] for row in panels), "Responsive ownership must not expose a guessed authored value.")
        identities = {(row["storyId"], row["elementId"], row["selector"]) for row in bindings}
        for ordinal, (row, property, value) in enumerate([(target, "border-radius", "5px"), (panels[1], "border-radius", "6px")]):
            current = next(binding for binding in bindings if binding["key"] == row["key"])
            request = {"command": "inspector-edit", "commandId": "provider-" + str(ordinal), "expectedRevision": ordinal,
                "schemaKey": current["key"], "target": current["elementId"], "storyId": current["storyId"],
                "property": property, "value": value, "expectedValue": current["values"][property],
                "expectedSourceHash": current["sourceHash"], "viewportWidth": 1440}
            path = directory / "request.json"
            path.write_text(json.dumps(request))
            operation = subprocess.run([str(binary), "source-project", str(project), str(path)],
                env=env, capture_output=True, text=True, timeout=90)
            (directory / ("operation-" + str(ordinal) + ".log")).write_text(operation.stdout + operation.stderr)
            self.assertEqual(operation.returncode, 0, operation.stdout + operation.stderr)
            result = json.loads(operation.stdout)
            self.assertTrue(result["ok"])
            bindings = result["editableStyles"]
            self.assertEqual({(row["storyId"], row["elementId"], row["selector"]) for row in bindings}, identities)
            for panel in [row for row in bindings if row["selector"] == ".panel"]:
                self.assertEqual(panel["values"][property], value)
                self.assertEqual(panel["sourceHash"], hashlib.sha1(source.read_bytes()).hexdigest().upper())
            self.assertEqual(json.loads((project / manifest["catalog"]).read_text()), result["catalog"])
            self.assertTrue(all(value in story["documentHtml"] for story in result["catalog"]["stories"]))
        expected = original.replace(b".panel { border:1px solid var(--rule); border-radius:4px;", b".panel { border:1px solid var(--rule); border-radius:6px;")
        self.assertEqual(source.read_bytes(), expected, "Only the declared shared rule values may change.")
        self.assertEqual((prototype / "src/components/styles.nim").read_bytes(), original, "Protected project bytes must stay untouched.")
        (directory / "proof.json").write_text(json.dumps({"bindingCount": len(bindings), "panelMatches": len(panels), "source": str(source)}))
        print("Source provider proof:", directory)


    def test_real_grip_token_and_derived_side_guarded_exact_restore(self):
        prototype = Path(os.environ.get("ISONIM_SOURCE_PROVIDER_PROJECT", REPO.parent / "web-site-prototypes/grip/isonim"))
        self.assertTrue((prototype / "src/components/styles.nim").is_file())
        directory = Path(tempfile.mkdtemp(prefix="source-values-provider-", dir=os.environ.get("ISONIM_POPUP_ARTIFACTS")))
        project = directory / "project"
        shutil.copytree(prototype, project, ignore=shutil.ignore_patterns(".git", ".repro", "build", "node_modules", "catalog-producer"))
        (project / "config.nims").write_text('switch("nimcache", ' + json.dumps(str(project / "native-cache")) + ')\n')
        source = project / "src/components/styles.nim"
        original = source.read_text()
        protected = (prototype / "src/components/styles.nim").read_bytes()
        manifest_path = project / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["editableStyleSources"] = [
            {"file": "src/components/styles.nim", "const": "structureCss", "properties": ["padding", "border-radius", "background"]},
            {"file": "src/components/styles.nim", "const": "designTokens", "properties": ["--panel"]}]
        manifest_path.write_text(json.dumps(manifest))
        env = {**os.environ, "ISONIM_SOURCE_FRAMEWORK": str(REPO)}
        binary = REPO / "build/bin/isonim-review"
        build = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(project)], env=env, capture_output=True, text=True, timeout=90)
        (directory / "catalog-build.log").write_text(build.stdout + build.stderr)
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
        described = subprocess.run([str(binary), "source-project", str(project), "--describe"], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(described.returncode, 0, described.stdout + described.stderr)
        bindings = json.loads(described.stdout)["editableStyles"]
        panel = next(row for row in bindings if row["selector"] == ".panel" and row["storyId"] == "Pages / Home")
        token = next(row for row in bindings if row["elementId"] == panel["elementId"] and row.get("tokenName") == "--panel")
        operation_count = 0
        receipts = []
        def perform(key, property, value, restoration=None, accepted=True):
            nonlocal bindings, operation_count
            current = next(row for row in bindings if row["key"] == key)
            request = {"command": "inspector-edit", "commandId": "native-values-" + str(operation_count), "expectedRevision": operation_count,
                "target": current["elementId"], "storyId": current["storyId"], "schemaKey": key,
                "property": property, "value": value, "expectedValue": current["values"][property],
                "expectedSourceHash": current["sourceHash"], "viewportWidth": 1440}
            if restoration is not None: request["sourceValue"] = restoration
            request_path = directory / "request.json"
            request_path.write_text(json.dumps(request))
            before_source, before_catalog = source.read_bytes(), (project / ".isonim/catalog.json").read_bytes()
            run = subprocess.run([str(binary), "source-project", str(project), str(request_path)], env=env, capture_output=True, text=True, timeout=90)
            (directory / ("operation-" + str(operation_count) + ".log")).write_text(run.stdout + run.stderr)
            operation_count += 1
            output = json.loads(run.stdout)
            self.assertEqual(output["ok"], accepted, run.stdout + run.stderr)
            self.assertEqual(run.returncode == 0, accepted)
            if accepted:
                bindings = output["editableStyles"]
                receipts.append(output["sourceEdit"])
            else:
                self.assertEqual(source.read_bytes(), before_source)
                self.assertEqual((project / ".isonim/catalog.json").read_bytes(), before_catalog)
            return output
        perform(token["key"], "background-color", "#123456")
        token_source = original.replace("--panel:#fbfbfc;", "--panel:#123456;")
        self.assertEqual(source.read_text(), token_source)
        self.assertIn("background:var(--panel)", source.read_text())
        first = perform(panel["key"], "border-top-left-radius", "8px")["sourceEdit"]
        prefix = ".panel { border:1px solid var(--rule); border-radius:"
        self.assertEqual(source.read_text(), token_source.replace(prefix + "4px;", prefix + "8px 4px 4px;"))
        second = perform(panel["key"], "border-top-right-radius", "12px")["sourceEdit"]
        self.assertEqual(source.read_text(), token_source.replace(prefix + "4px;", prefix + "8px 12px 4px 4px;"))
        perform(panel["key"], "border-top-right-radius", "4px", second["before"])
        self.assertEqual(source.read_text(), token_source.replace(prefix + "4px;", prefix + "8px 4px 4px;"))
        sibling = perform(panel["key"], "border-bottom-right-radius", "16px")["sourceEdit"]
        perform(panel["key"], "border-top-left-radius", "4px", first["before"], accepted=False)
        perform(panel["key"], "border-top-left-radius", "4px", "4px; color:red", accepted=False)
        perform(panel["key"], "border-bottom-right-radius", "4px", sibling["before"])
        perform(panel["key"], "border-top-left-radius", "4px", first["before"])
        self.assertEqual(source.read_text(), token_source)
        perform(token["key"], "background-color", "#fbfbfc", "#fbfbfc")
        self.assertEqual(source.read_text(), original)
        self.assertEqual((prototype / "src/components/styles.nim").read_bytes(), protected)
        (directory / "proof.json").write_text(json.dumps({"operations": operation_count, "receipts": receipts, "nativeSha256": hashlib.sha256(binary.read_bytes()).hexdigest()}, indent=2))

if __name__ == "__main__":
    unittest.main()
