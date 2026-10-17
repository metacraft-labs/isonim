"""Real native inspector source transactions against private files/Nim/SSR builds.

No storage, patcher, adapter, compiler or worker is mocked. The project fixture's
compile-time assertion deliberately rejects one valid CSS width, exercising
rollback after an actual compiler failure rather than a fabricated failure result.
Browser authentication and mounted gestures are covered by the registered route
and full GUI suites; this file verifies the authoritative native transaction.
"""
import json
import hashlib
import re
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent

class InspectorSourceTransactionTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="inspector-native-", dir=os.environ.get("ISONIM_POPUP_ARTIFACTS")))
        self.project = self.directory / "project"
        shutil.copytree(REPO / "tests/fixtures/editor_inspector_project", self.project)
        self.binary = REPO / "build/bin/isonim-review"
        self.env = {**os.environ, "ISONIM_SOURCE_FRAMEWORK": str(REPO)}
        build = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)],
                               env=self.env, capture_output=True, text=True, timeout=70)
        (self.directory / "initial-build.log").write_text(build.stdout + build.stderr)
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
        self.source = self.project / "stories.nim"
        self.catalog = self.project / ".isonim/catalog.json"
        self.original = self.source.read_bytes()
        self.original_catalog = self.catalog.read_bytes()

    def metadata(self):
        result = subprocess.run([str(self.binary), "source-project", str(self.project), "--describe"],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)["editableStyles"]

    def request(self, target="action", property="width", value="240px"):
        entry = next(entry for entry in self.metadata() if entry["elementId"] == target and property in entry["values"])
        return {"command": "inspector-edit", "commandId": "native-acceptance", "expectedRevision": 0,
                "schemaKey": entry["key"], "target": entry["elementId"], "storyId": entry["storyId"],
                "property": property, "value": value, "expectedValue": entry["values"][property],
                "expectedSourceHash": entry["sourceHash"], "viewportWidth": 1440}

    def operate(self, request, expected=0):
        payload = self.directory / "request.json"
        payload.write_text(json.dumps(request))
        result = subprocess.run([str(self.binary), "source-project", str(self.project), str(payload)],
                                env=self.env, capture_output=True, text=True, timeout=120)
        (self.directory / "operation.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def unchanged(self):
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.catalog.read_bytes(), self.original_catalog)
        self.assertFalse((self.project / ".isonim/source-transaction.json").exists())

    def test_equal_literal_validates_real_source_without_write_or_build(self):
        request = self.request(value="120px")
        # Temporarily make the actual project compiler entry unavailable. A
        # validated no-op must not invoke it or publish/write anything.
        build_entry = self.project / "build_catalog.py"
        parked_entry = self.project / "build_catalog.py.parked"
        build_entry.rename(parked_entry)
        before_times = (self.source.stat().st_mtime_ns, self.catalog.stat().st_mtime_ns)
        try:
            result = self.operate(request)
        finally:
            parked_entry.rename(build_entry)
        self.assertTrue(result["ok"])
        self.assertTrue(result["sourceEdit"]["unchanged"])
        self.assertEqual(result["sourceEdit"]["before"], "120px")
        self.assertEqual(result["sourceEdit"]["after"], "120px")
        self.assertEqual((self.source.stat().st_mtime_ns, self.catalog.stat().st_mtime_ns), before_times)
        self.unchanged()
        external = self.original.replace(b"width:120px", b"width:121px")
        self.source.write_bytes(external)
        refused = self.operate(request, expected=4)
        self.assertFalse(refused["ok"])
        self.assertIn("Source changed", refused["diagnostic"])
        self.assertEqual(self.source.read_bytes(), external)
        self.assertEqual(self.catalog.read_bytes(), self.original_catalog)
        self.assertFalse((self.project / ".isonim/source-transaction.json").exists())

    def test_distinct_declared_targets_and_properties_compile_and_persist(self):
        for target, property, value in [("action", "width", "240px"),
                                         ("secondary-action", "height", "64px"),
                                         ("alternate-action", "background-color", "#abcdef80")]:
            with self.subTest(target=target, property=property):
                result = self.operate(self.request(target, property, value))
                self.assertTrue(result["ok"])
                metadata = next(row for row in result["editableStyles"] if row["elementId"] == target)
                self.assertEqual(metadata["values"][property], value)
                self.assertEqual(json.loads(self.catalog.read_text()), result["catalog"])
                rendered = next(story["documentHtml"] for story in result["catalog"]["stories"]
                                if story["group"] + " / " + story["name"] == metadata["storyId"])
                self.assertIn(value, rendered)
                self.assertNotIn("<rawHtml>", rendered)
        self.assertIn("#action { width:240px; height:48px;", self.source.read_text())
        self.assertIn("#secondary-action { width:160px; height:64px;", self.source.read_text())

    def test_real_compiler_failure_restores_exact_source_and_published_catalog(self):
        result = self.operate(self.request(value="777px"), expected=4)
        self.assertFalse(result["ok"])
        self.assertIn("AssertionDefect", result["diagnostic"])
        self.unchanged()

    def test_project_cache_recompiles_edits_failure_retry_and_isolates_copies(self):
        self.operate(self.request(value="130px"))
        self.assertIn("width:130px;", self.catalog.read_text())
        before_source, before_catalog = self.source.read_bytes(), self.catalog.read_bytes()
        self.operate(self.request(value="777px"), expected=4)
        self.assertEqual(self.source.read_bytes(), before_source)
        self.assertEqual(self.catalog.read_bytes(), before_catalog)
        self.operate(self.request(value="140px"))
        self.assertIn("width:140px;", self.catalog.read_text())
        other = self.directory / "other-project"
        shutil.copytree(REPO / "tests/fixtures/editor_inspector_project", other)
        build = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(other)],
                               env=self.env, capture_output=True, text=True, timeout=70)
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
        self.assertIn("width:120px;", (other / ".isonim/catalog.json").read_text())
        first_cache, other_cache = self.project / ".isonim/native-cache", other / ".isonim/native-cache"
        self.assertTrue(first_cache.is_dir() and other_cache.is_dir())
        self.assertNotEqual(first_cache.resolve(), other_cache.resolve())
        first_objects = {item.name: item for item in first_cache.glob("*.o")}
        other_objects = {item.name: item for item in other_cache.glob("*.o")}
        common = first_objects.keys() & other_objects.keys()
        self.assertTrue(common)
        for name in common:
            self.assertNotEqual(first_objects[name].stat().st_ino, other_objects[name].stat().st_ino)

    def test_stale_source_hash_does_not_overwrite_a_human_edit(self):
        request = self.request()
        self.source.write_bytes(self.original + b"\n# independent human edit\n")
        human = self.source.read_bytes()
        result = self.operate(request, expected=4)
        self.assertIn("Source changed", result["diagnostic"])
        self.assertEqual(self.source.read_bytes(), human)
        self.assertEqual(self.catalog.read_bytes(), self.original_catalog)

    def test_stale_declaration_value_is_independently_rejected(self):
        request = self.request()
        request["expectedValue"] = "999px"
        result = self.operate(request, expected=4)
        self.assertEqual(result["diagnostic"], "Authored property changed before this edit.")
        self.unchanged()

    def test_unsupported_schema_target_story_and_property_are_refused(self):
        for key, value in [("schemaKey", "unsupported"), ("target", "secondary-action"),
                           ("storyId", "Alternate / default ready"), ("property", "unknown-property")]:
            with self.subTest(key=key):
                request = self.request()
                request[key] = value
                result = self.operate(request, expected=4)
                self.assertFalse(result["ok"])
                self.unchanged()

    def test_invalid_value_delimiters_and_non_finite_numeric_are_refused(self):
        for value in ["NaNpx", "Infinitypx", "infpx", "1e999px", "20", "NaN", "Infinity", "20px; color:red", "20px}\necho 1", '20px"""']:
            with self.subTest(value=value):
                result = self.operate(self.request(value=value), expected=4)
                self.assertFalse(result["ok"])
                self.unchanged()

    def test_percentage_hue_cannot_publish_source(self):
        result = self.operate(self.request(property="background-color", value="hsl(10%,50%,50%)"), expected=4)
        self.assertFalse(result["ok"])
        self.unchanged()

    def test_finite_color_functions_compile_and_restore_exact_source(self):
        for value in ["rgb(18, 52, 86)", "rgba(18, 52, 86, 0.5)",
                      "rgb(10% 20% 30% / 50%)", "hsl(120deg, 50%, 25%)",
                      "rgba(18,52,86)", "hsla(120,50%,25%)", "hsl(10 50 50)"]:
            self.operate(self.request(property="background-color", value=value))
            self.assertIn("background-color:" + value.lower() + ";", self.source.read_text())
            self.assertIn(value.lower(), self.catalog.read_text())
        self.operate(self.request(property="background-color", value="#112233"))
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_malformed_and_non_finite_color_functions_never_publish_source(self):
        for value in ["rgb(NaN, 2, 3)", "rgba(1, 2, 3, Infinity)", "rgb(1e999, 2, 3)",
                      "rgb(1, 2)", "rgb(1, 2, 3)junk", "hsl(10, junk, 20%)",
                      "rgb(10%,20,30)", "RGB(NaN,2,3)"]:
            with self.subTest(value=value):
                result = self.operate(self.request(property="background-color", value=value), expected=4)
                self.assertFalse(result["ok"])
                self.unchanged()

    def test_unknown_paths_malformed_types_and_missing_fields_are_refused(self):
        for key, value in [("file", "../other.nim"), ("value", True), ("expectedSourceHash", 42),
                           ("viewportWidth", "1440"), ("expectedRevision", None)]:
            with self.subTest(key=key):
                request = self.request()
                request[key] = value
                self.assertFalse(self.operate(request, expected=4)["ok"])
                self.unchanged()
        request = self.request()
        del request["property"]
        self.assertFalse(self.operate(request, expected=4)["ok"])
        self.unchanged()

    def test_manifest_source_path_cannot_escape_or_traverse_a_symlink(self):
        manifest_path = self.project / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        request = self.request()
        outside = self.directory / "outside.nim"
        outside.write_bytes(self.original)
        for path in ["../outside.nim", "alias.nim"]:
            with self.subTest(path=path):
                if path == "alias.nim": (self.project / path).symlink_to(outside)
                manifest["editableStyles"][0]["file"] = path
                manifest_path.write_text(json.dumps(manifest))
                self.assertFalse(self.operate(request, expected=4)["ok"])
                self.unchanged()
                self.assertEqual(outside.read_bytes(), self.original)

    def test_provider_background_effective_owner_real_css_compile_restore_and_refusal(self):
        # Actual source/native/compiler transactions; Chromium computes the CSS
        # from each compiled catalog. setContent isolates CSS ownership from UI
        # selection overlays; mounted source GUI separately exercises the editor.
        manifest_path = self.project / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        manifest.pop("editableStyles")
        manifest["editableStyleSources"] = [{"file":"stories.nim", "const":"cardStyles",
            "properties":["background", "background-color"]}]
        manifest_path.write_text(json.dumps(manifest))
        # The native adapter publishes compact catalog JSON. This project's
        # real producer uses the identical representation so exact-byte undo
        # checks compare a settled publication, not its initial trailing LF.
        producer = self.project / "build_catalog.py"
        producer.write_text(producer.read_text().replace("sys.stdout.write(rendered.stdout)",
            'sys.stdout.write(json.dumps(json.loads(rendered.stdout), separators=(",", ":")))'))
        template = self.source.read_text().replace('doAssert "width:777px" notin cardStyles',
            'doAssert "width:777px" notin cardStyles\n  doAssert "#010203" notin cardStyles')
        computed = []
        def compile_case(css, label):
            source = re.sub(r"#action \{[^}]*\}", "#action { " + css + " }", template, count=1)
            self.source.write_text(source)
            built = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)],
                env=self.env, capture_output=True, text=True, timeout=70)
            (self.directory / (label + "-build.log")).write_text(built.stdout + built.stderr)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            return self.source.read_bytes(), self.catalog.read_bytes()
        def capture(label, expected):
            catalog = json.loads(self.catalog.read_text())
            html = next(story["documentHtml"] for story in catalog["stories"] if story["group"] == "Card")
            computed.append({"label":label,"html":html,"expected":expected})
        for ordinal, (css, owner, expected) in enumerate([
            ("background-color:#112233; background:#445566;", "background", "#445566"),
            ("background:#445566; background-color:#112233;", "background-color", "#112233"),
            ("background:linear-gradient(red,blue); background-color:#112233;", "background-color", "#112233"),
            ("background:#445566;", "background", "#445566"),
            ("background-color:#112233; background:#445566;", "background", "#445566")]):
            with self.subTest(css=css):
                manifest["editableStyleSources"][0]["properties"] = ["background"] if ordinal == 4 else ["background", "background-color"]
                manifest_path.write_text(json.dumps(manifest))
                original, catalog_before = compile_case(css, "positive-" + str(ordinal))
                entry = next(row for row in self.metadata() if row["elementId"] == "action")
                self.assertEqual(entry["values"]["background-color"], expected)
                self.assertEqual(entry["sourceDeclarations"]["background-color"]["property"], owner)
                capture("positive-before-" + str(ordinal), expected)
                request = self.request(property="background-color", value="#abcdef")
                changed = self.operate(request)
                self.assertTrue(changed["ok"])
                self.assertEqual(self.source.read_bytes(), original.replace((owner + ":" + expected).encode(),
                    (owner + ":#abcdef").encode(), 1))
                capture("positive-after-" + str(ordinal), "#abcdef")
                restored = self.operate(self.request(property="background-color", value=expected))
                self.assertTrue(restored["ok"])
                self.assertEqual(self.source.read_bytes(), original)
                self.assertEqual(self.catalog.read_bytes(), catalog_before)
                capture("positive-native-undo-" + str(ordinal), expected)
                failed = self.operate(self.request(property="background-color", value="#010203"), expected=4)
                self.assertFalse(failed["ok"])
                self.assertIn("AssertionDefect", failed["diagnostic"])
                self.assertEqual(self.source.read_bytes(), original)
                self.assertEqual(self.catalog.read_bytes(), catalog_before)
        manifest["editableStyleSources"][0]["properties"] = ["background", "background-color"]
        manifest_path.write_text(json.dumps(manifest))
        compile_case("background-color:#112233;", "admitted-baseline")
        stale_capability = self.request(property="background-color", value="#abcdef")
        for ordinal, (css, expected) in enumerate([
            ("background-color:#112233; background:#445566 !important;", "#445566"),
            ("background-color:#112233; background:#445566; background:#778899;", "#778899"),
            ("background-color:#112233; background:linear-gradient(red,blue);", "transparent"),
            ("background:#445566; background-color:#112233 !important;", "#112233"),
            ("background-color:#112233; background-color:#445566;", "#445566"),
            ("background-color:#112233; } @media(min-width:100px) { #action { background:#445566;", "#445566")]):
            for allowed in [["background-color"], ["background", "background-color"]]:
                with self.subTest(css=css, allowed=allowed):
                    manifest["editableStyleSources"][0]["properties"] = allowed
                    manifest_path.write_text(json.dumps(manifest))
                    original, catalog_before = compile_case(css, "refused-" + str(ordinal))
                    self.assertFalse(any(row["elementId"] == "action" and "background-color" in row["values"]
                        for row in self.metadata()))
                    request = {**stale_capability, "expectedSourceHash":hashlib.sha1(original).hexdigest().upper()}
                    self.assertFalse(self.operate(request, expected=4)["ok"])
                    self.assertEqual(self.source.read_bytes(), original)
                    self.assertEqual(self.catalog.read_bytes(), catalog_before)
                    self.assertFalse((self.project / ".isonim/source-transaction.json").exists())
                    capture("refused-" + str(ordinal) + "-" + str(len(allowed)), expected)
        manifest["editableStyleSources"][0]["properties"] = ["background"]
        manifest_path.write_text(json.dumps(manifest))
        original, catalog_before = compile_case("background:#445566; background-color:#112233;", "projection-only-owner")
        self.assertFalse(any(row["elementId"] == "action" for row in self.metadata()))
        request = {**stale_capability,"expectedSourceHash":hashlib.sha1(original).hexdigest().upper()}
        self.assertFalse(self.operate(request, expected=4)["ok"])
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(self.catalog.read_bytes(), catalog_before)
        capture("projection-only-winning-longhand","#112233")
        # Current-origin attribution is checked on real SSR inline/conditional
        # owners, not only synthetic catalog rows. Explicit bindings retain the
        # separately executed original source-transaction tests above.
        manifest["editableStyleSources"][0]["properties"] = ["width"]
        manifest_path.write_text(json.dumps(manifest))
        for ordinal, (css, inline, expected, allowed) in enumerate([
            ("width:40px;", True, "60px", False),
            ("width:40px; } @media(min-width:100px) { #action { width:60px;", False, "60px", False),
            ("width:40px; } #action:hover { width:60px;", False, "40px", False),
            ("width:40px; } @media(min-width:100px) { #other { width:60px;", False, "40px", True)]):
            base_template = template
            if inline:
                template = template.replace('button(id = target, `data-isonim-element-id` = target)',
                    'button(id = target, `data-isonim-element-id` = target, style = "width:60px")')
            original, catalog_before = compile_case(css,"attribution-" + str(ordinal))
            template = base_template
            capture("attribution-before-" + str(ordinal), expected)
            computed[-1]["property"] = "width"
            entries = [row for row in self.metadata() if row["elementId"] == "action" and "width" in row["values"]]
            self.assertEqual(bool(entries), allowed)
            if allowed:
                self.operate(self.request(property="width",value="64px"))
                capture("attribution-safe-after","64px")
                computed[-1]["property"] = "width"
                self.operate(self.request(property="width",value="40px"))
                capture("attribution-safe-undo","40px")
                computed[-1]["property"] = "width"
            else:
                request = {**stale_capability,"property":"width","value":"64px",
                    "expectedValue":"40px","expectedSourceHash":hashlib.sha1(original).hexdigest().upper()}
                self.assertFalse(self.operate(request, expected=4)["ok"])
            self.assertEqual(self.source.read_bytes(), original)
            self.assertEqual(self.catalog.read_bytes(), catalog_before)
        self.check_compiled_css(computed)
        self.assertEqual(len(json.loads((self.directory / "computed-proof.json").read_text())), 34)

    def check_compiled_css(self, rows, prefix="computed"):
        """Actual Chromium cascade over compiled HTML; no copied CSS evaluator.

        This isolates native capability/compiled style ownership from selection
        overlays. The registered real mounted suites cover editor interactions.
        """
        payload = self.directory / (prefix + "-input.json")
        payload.write_text(json.dumps(rows))
        script = r"""
import {chromium} from './node_modules/playwright/index.mjs';
import {readFileSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const env={...process.env};delete env.LD_LIBRARY_PATH;
const server=await chromium.launchServer({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,env});
const browser=await chromium.connect(server.wsEndpoint());
try {const page=await browser.newPage({viewport:{width:1440,height:900}});const proof=[];
for(const row of JSON.parse(readFileSync(process.argv[1],'utf8'))){await page.setContent(row.html);if(row.hover)await page.locator('#action').hover();
if(row.reset){const actual=await page.locator('#action').evaluate(node=>({width:getComputedStyle(node).width,background:getComputedStyle(node).backgroundColor}));assert.notEqual(actual.width,'40px',row.label);assert.equal(actual.background,'rgba(0, 0, 0, 0)',row.label);proof.push({label:row.label,actual});continue;}
if(row.exceptions){const actual=await page.locator('#action').evaluate(node=>({direction:getComputedStyle(node).direction,unicodeBidi:getComputedStyle(node).unicodeBidi}));assert.deepEqual(actual,{direction:'rtl',unicodeBidi:'isolate'},row.label);proof.push({label:row.label,actual});continue;}
const actual=await page.locator('#action').evaluate((node,property)=>getComputedStyle(node)[property],row.property||'backgroundColor');
const expected=await page.evaluate(({color,property})=>{const probe=document.createElement('div');probe.style[property]=color;document.body.appendChild(probe);const value=getComputedStyle(probe)[property];probe.remove();return value;},{color:row.expected,property:row.property||'backgroundColor'});
assert.equal(actual,expected,row.label);proof.push({label:row.label,actual,expected});}
writeFileSync(process.argv[2],JSON.stringify(proof,null,2));console.log('Actual compiled CSS cases:',proof.length);
}finally{await browser.close();await server.close();}
"""
        browser = subprocess.run([os.environ.get("ISONIM_SCENARIO_NODE", "node"), "--input-type=module", "-e", script,
            str(payload), str(self.directory / (prefix + "-proof.json"))], cwd=REPO, env=self.env,
            capture_output=True, text=True, timeout=70)
        (self.directory / (prefix + "-browser.log")).write_text(browser.stdout + browser.stderr)
        self.assertEqual(browser.returncode, 0, browser.stdout + browser.stderr)

    def test_provider_all_reset_refuses_false_origins_with_exact_source_catalog_and_exceptions(self):
        # Real native worker/SSR/compiler; the test adds declarations only to a
        # disposable project, including actual inline/ancestor/state subjects.
        manifest_path = self.project / ".isonim/source-project.json"
        manifest = json.loads(manifest_path.read_text())
        manifest.pop("editableStyles")
        manifest["editableStyleSources"] = [{"file":"stories.nim","const":"cardStyles",
            "properties":["width","background-color","direction","unicode-bidi","--panel"]}]
        manifest_path.write_text(json.dumps(manifest))
        producer = self.project / "build_catalog.py"
        producer.write_text(producer.read_text().replace("sys.stdout.write(rendered.stdout)",
            'sys.stdout.write(json.dumps(json.loads(rendered.stdout), separators=(",", ":")))'))
        template = self.source.read_text().replace('button(id = target, `data-isonim-element-id` = target)',
            'button(id = target, `data-isonim-element-id` = target, class = "panel", `data-kind` = "active")')
        template = template.replace('        main:', '        main(class = "host"):')
        template = template.replace('doAssert "width:777px" notin cardStyles',
            'doAssert "width:777px" notin cardStyles\n  doAssert "#010203" notin cardStyles')
        rows = []
        def setup(css, label, inline=False):
            text = re.sub(r"#action \{[^}]*\}", "#action { " + css + " }", template, count=1)
            if inline:
                text = text.replace('class = "panel", `data-kind` = "active")',
                    'class = "panel", `data-kind` = "active", style = "all:initial")')
            self.source.write_text(text)
            build = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)],
                env=self.env,capture_output=True,text=True,timeout=70)
            (self.directory / (label + "-build.log")).write_text(build.stdout + build.stderr)
            self.assertEqual(build.returncode,0,build.stdout + build.stderr)
            return self.source.read_bytes(),self.catalog.read_bytes()
        def capture(label, **expected):
            html = next(story["documentHtml"] for story in json.loads(self.catalog.read_text())["stories"] if story["group"] == "Card")
            rows.append({"label":label,"html":html,**expected})
        base = "width:40px; background-color:#112233;"
        setup(base,"all-admission-baseline")
        valid = self.request(property="width",value="64px")
        for ordinal,(tail,inline,hover) in enumerate([
            (" all:initial;",False,False),
            ("",True,False),
            (" } @media(min-width:100px) { #action { all:initial;",False,False),
            (" } #action[data-kind=active] { all:initial;",False,False),
            (" } #action:hover { all:initial;",False,True),
            (" } .host #action { all:initial;",False,False)]):
            original,catalog_before = setup(base + tail,"all-refused-" + str(ordinal),inline)
            entries = [entry for entry in self.metadata() if entry["elementId"] == "action"]
            self.assertFalse(any("width" in entry["values"] or "background-color" in entry["values"] for entry in entries))
            request = {**valid,"expectedSourceHash":hashlib.sha1(original).hexdigest().upper()}
            self.assertFalse(self.operate(request,expected=4)["ok"])
            self.assertEqual(self.source.read_bytes(),original)
            self.assertEqual(self.catalog.read_bytes(),catalog_before)
            self.assertFalse((self.project / ".isonim/source-transaction.json").exists())
            capture("all-refused-" + str(ordinal),reset=True,hover=hover)
        original,catalog_before = setup(base + " } .panel .other:hover { all:initial;","all-unrelated")
        self.operate(self.request(property="width",value="64px"))
        self.assertEqual(self.source.read_bytes(),original.replace(b"width:40px",b"width:64px",1))
        capture("all-unrelated-edit",expected="64px",property="width")
        self.operate(self.request(property="width",value="40px"))
        self.assertEqual(self.source.read_bytes(),original)
        self.assertEqual(self.catalog.read_bytes(),catalog_before)
        capture("all-unrelated-undo",expected="40px",property="width")
        original,catalog_before = setup("direction:rtl; unicode-bidi:isolate; all:initial;","all-exceptions")
        entries = [entry for entry in self.metadata() if entry["elementId"] == "action"]
        self.assertEqual(len(entries),1)
        self.assertEqual(entries[0]["values"],{"direction":"rtl","unicode-bidi":"isolate"})
        capture("all-nonreset-exceptions",exceptions=True)
        token_css = "width:40px; background-color:var(--panel); } :root { --panel:#112233; all:initial;"
        original,catalog_before = setup(token_css,"all-root-token")
        token = next(entry for entry in self.metadata() if entry["elementId"] == "action" and entry.get("tokenName") == "--panel")
        self.assertEqual(token["values"]["background-color"],"#112233")
        capture("all-root-token-before",expected="#112233")
        self.operate(self.request(property="background-color",value="#abcdef"))
        self.assertEqual(self.source.read_bytes(),original.replace(b"--panel:#112233",b"--panel:#abcdef",1))
        self.assertIn("background-color:var(--panel)",self.source.read_text())
        capture("all-root-token-edit",expected="#abcdef")
        self.operate(self.request(property="background-color",value="#112233"))
        self.assertEqual(self.source.read_bytes(),original)
        self.assertEqual(self.catalog.read_bytes(),catalog_before)
        capture("all-root-token-undo",expected="#112233")
        rejected = self.operate(self.request(property="background-color",value="#010203"),expected=4)
        self.assertIn("AssertionDefect",rejected["diagnostic"])
        self.assertEqual(self.source.read_bytes(),original)
        self.assertEqual(self.catalog.read_bytes(),catalog_before)
        self.check_compiled_css(rows,prefix="all-reset")
        self.assertEqual(len(json.loads((self.directory / "all-reset-proof.json").read_text())),12)
        print("All reset source transaction proof:",self.directory)

    def test_owned_binding_sidecar_revision_save_reload_and_source_isolation(self):
        sidecar = self.project / ".isonim/bindings.json"
        raw = json.dumps({"version": 1, "variableBindings": [
            {"elementId": "action", "propertyName": "background-color", "variableKey": "color/surface"}],
            "variableBindingHistory": [{"elementId": "action", "propertyName": "background-color",
                                        "variableKeys": ["color/surface"]}]})
        snapshot = subprocess.run([str(self.binary), "source-project", str(self.project), "--snapshot"],
                                  env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(snapshot.returncode, 0, snapshot.stdout + snapshot.stderr)
        initial = json.loads(snapshot.stdout)
        self.assertEqual(initial["bindingSidecar"], "")
        saved = self.operate({"command": "bindings-save", "commandId": "binding-save",
                              "expectedBindingHash": initial["bindingHash"], "bindingSidecar": raw})
        self.assertTrue(saved["ok"])
        self.assertEqual(json.loads(sidecar.read_text()), json.loads(raw))
        self.assertEqual(saved["bindingHash"], hashlib.sha1(sidecar.read_bytes()).hexdigest().upper())
        self.unchanged()
        # Independent tab still carries the actual initial revision. It must
        # not overwrite the first tab's durable metadata with an empty set.
        before = sidecar.read_bytes()
        rejected = self.operate({"command": "bindings-save", "commandId": "second-tab",
                                 "expectedBindingHash": initial["bindingHash"],
                                 "bindingSidecar": json.dumps({"version": 1, "variableBindings": [],
                                                              "variableBindingHistory": []})}, expected=4)
        self.assertFalse(rejected["ok"])
        self.assertIn("Binding metadata changed", rejected["diagnostic"])
        self.assertEqual(sidecar.read_bytes(), before)
        self.unchanged()
        reloaded = subprocess.run([str(self.binary), "source-project", str(self.project), "--snapshot"],
                                   env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(reloaded.returncode, 0)
        self.assertEqual(json.loads(json.loads(reloaded.stdout)["bindingSidecar"]), json.loads(raw))

    def test_binding_sidecar_rejects_escape_symlink_and_invalid_metadata(self):
        outside = self.directory / "outside-bindings.json"
        outside.write_text("do not overwrite")
        sidecar = self.project / ".isonim/bindings.json"
        sidecar.symlink_to(outside)
        request = {"command": "bindings-save", "commandId": "unsafe",
                   "expectedBindingHash": hashlib.sha1(b"").hexdigest().upper(),
                   "bindingSidecar": '{"version":1,"variableBindings":[],"variableBindingHistory":[]}'}
        refused = self.operate(request, expected=4)
        self.assertIn("symlinks", refused["diagnostic"])
        self.assertEqual(outside.read_text(), "do not overwrite")
        sidecar.unlink()
        request["bindingSidecar"] = '{"version":1,"variableBindings":"invalid","variableBindingHistory":[]}'
        refused = self.operate(request, expected=4)
        self.assertIn("Invalid binding metadata", refused["diagnostic"])
        self.assertFalse(sidecar.exists())
        self.unchanged()

class NativeDeclarationRemovalTests(InspectorSourceTransactionTests):
    """Reset / Fill Delete through the native writer: remove the one owning
    declaration (editor spec "Universal Patterns": Reset reverts to the
    class, token or inherited value; each source-map entry states whether
    its writer can remove the declaration it owns; undo puts back exactly the
    line it removed. "Saving": a refusal known at the act is made there).

    The same real worker, files and project compiler as the suite above; no
    mock. Inherits its fixture and helpers only (the inherited cases are
    filtered out below so they run once)."""

    ACTION_LINE = (b"#action { width:120px; height:48px; padding:8px; padding-top:1em; "
                   b"padding-right:2px; padding-bottom:3px; padding-left:4px; border-radius:4px; "
                   b"border-top-left-radius:1em; border-top-right-radius:2px; "
                   b"border-bottom-right-radius:3px; border-bottom-left-radius:4px; "
                   b"background-color:#112233; color:#FFFFFF; }\n")

    def file_hash(self, file="stories.nim"):
        return next(row["sourceHash"] for row in self.metadata() if row["file"] == file)

    def undo_removal(self, request, removed, expected=0, receipt=None, source_hash=None):
        undo = dict(request, commandId="native-undo", value=removed["sourceEdit"]["before"],
                    expectedValue="", restoreWrite=receipt or removed["sourceEdit"]["receipt"],
                    expectedSourceHash=source_hash or self.file_hash())
        return self.operate(undo, expected)

    def manifest_path(self):
        return self.project / ".isonim/source-project.json"

    def test_each_editable_declaration_states_whether_it_can_be_removed(self):
        self.assertIn(self.ACTION_LINE, self.original)
        # #action declares padding and border-radius together with all four
        # of their longhands: each of those is also set by another
        # declaration in the rule, so removing it would not reset it.
        overlapping = {"padding": "padding-top", "padding-top": "padding",
                       "padding-right": "padding", "padding-bottom": "padding",
                       "padding-left": "padding", "border-radius": "border-top-left-radius",
                       "border-top-left-radius": "border-radius", "border-top-right-radius": "border-radius",
                       "border-bottom-right-radius": "border-radius", "border-bottom-left-radius": "border-radius"}
        for row in self.metadata():
            with self.subTest(key=row["key"]):
                self.assertIn("removals", row)
                self.assertEqual(set(row["removals"]), set(row["values"]))
                for property, reason in row["removals"].items():
                    if row["key"] == "style.action" and property in overlapping:
                        self.assertIn("`" + overlapping[property] + "` also sets `" + property + "` for `#action`", reason)
                    else:
                        self.assertEqual(reason, "", property)
        # A duplicate, a conditional override and an absent declaration are
        # each stated per declaration, not by the project kind.
        manifest = json.loads(self.manifest_path().read_text())
        next(row for row in manifest["editableStyles"] if row["key"] == "style.action")["properties"].append("opacity")
        self.manifest_path().write_text(json.dumps(manifest))
        self.source.write_bytes(self.original
            .replace(b"#secondary-action { width:160px;", b"#secondary-action { width:160px; width:161px;")
            .replace(b'#alternate-action { width:180px; height:56px; padding:10px; border-radius:8px; background-color:#556677; color:#FFFFFF; }\n',
                     b'#alternate-action { width:180px; height:56px; padding:10px; border-radius:8px; background-color:#556677; color:#FFFFFF; }\n'
                     b'@media (max-width: 600px) { #alternate-action { color:#000000; } }\n'))
        rows = {row["key"]: row for row in self.metadata()}
        self.assertTrue(all("removals" in row for row in rows.values()))
        self.assertIn("2 declarations set `width`", rows["style.secondary-action"]["removals"]["width"])
        self.assertEqual(rows["style.secondary-action"]["removals"]["height"], "")
        self.assertIn("2 declarations set `color`", rows["style.alternate-action"]["removals"]["color"])
        self.assertIn("There is no `opacity` declaration", rows["style.action"]["removals"]["opacity"])
        self.assertEqual(rows["style.action"]["removals"]["width"], "")

    def test_removal_deletes_exactly_the_one_owning_declaration_and_undo_restores_its_line(self):
        request = self.request(property="background-color", value="")
        removed = self.operate(request)
        self.assertTrue(removed["ok"])
        expected = self.original.replace(b"border-bottom-left-radius:4px; background-color:#112233; color:#FFFFFF; }",
                                         b"border-bottom-left-radius:4px; color:#FFFFFF; }", 1)
        self.assertNotEqual(expected, self.original)
        self.assertEqual(self.source.read_bytes(), expected)
        self.assertFalse((self.project / ".isonim/source-transaction.json").exists())
        self.assertEqual(removed["sourceEdit"]["before"], "#112233")
        self.assertEqual(removed["sourceEdit"]["after"], "")
        self.assertTrue(removed["sourceEdit"]["removed"])
        receipt = removed["sourceEdit"]["receipt"]
        self.assertEqual(receipt["file"], "stories.nim")
        self.assertEqual(receipt["before"].encode(), self.ACTION_LINE)
        self.assertEqual(receipt["after"].encode(), self.ACTION_LINE.replace(b"background-color:#112233; ", b""))
        self.assertTrue(receipt["unique"])
        self.assertEqual(receipt["afterHash"], hashlib.sha1(expected).hexdigest().upper())
        self.assertEqual(json.loads(self.catalog.read_text()), removed["catalog"])
        card = next(story["documentHtml"] for story in removed["catalog"]["stories"] if story["group"] == "Card")
        self.assertNotIn("background-color:#112233", card)
        self.assertIn("background-color:#224466", card)
        action = next(row for row in removed["editableStyles"] if row["key"] == "style.action")
        self.assertEqual(action["values"]["background-color"], "")
        self.assertIn("There is no `background-color` declaration", action["removals"]["background-color"])
        # Undo puts back exactly the removed line, through its receipt.
        restored = self.undo_removal(request, removed)
        self.assertTrue(restored["ok"], restored)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(json.loads(self.catalog.read_text()), json.loads(self.original_catalog))
        self.assertFalse((self.project / ".isonim/source-transaction.json").exists())
        # Redo is the same single-match removal again; its undo is exact too.
        again_request = self.request(property="background-color", value="")
        again = self.operate(again_request)
        self.assertEqual(self.source.read_bytes(), expected)
        self.assertEqual(again["sourceEdit"]["receipt"], receipt)
        self.assertTrue(self.undo_removal(again_request, again)["ok"])
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_a_declaration_on_its_own_line_takes_the_line_with_it(self):
        multiline = self.original.replace(b"#reused-card { width:110px; height:40px; background-color:#224466; }\n",
                                          b"#reused-card {\n  width:110px;\n  height:40px;\n  background-color:#224466;\n}\n")
        self.source.write_bytes(multiline)
        request = self.request(target="reused", property="height", value="")
        removed = self.operate(request)
        self.assertEqual(self.source.read_bytes(), multiline.replace(b"  height:40px;\n", b"", 1))
        # Whole lines: the removed line plus the line the change ends on.
        receipt = removed["sourceEdit"]["receipt"]
        self.assertEqual(receipt["before"], "  height:40px;\n  background-color:#224466;\n")
        self.assertEqual(receipt["after"], "  background-color:#224466;\n")
        self.assertTrue(self.undo_removal(request, removed)["ok"])
        self.assertEqual(self.source.read_bytes(), multiline)

    def test_a_property_another_declaration_also_sets_is_refused_on_real_files(self):
        # The fixture's own #action: padding-top after padding, padding before
        # all four longhands (review P1/P2).
        for property, other in [("padding-top", "padding"), ("padding", "padding-top")]:
            with self.subTest(property=property):
                refused = self.operate(self.request(property=property, value=""), expected=4)
                self.assertIn("`" + other + "` also sets `" + property + "` for `#action`", refused["diagnostic"])
                self.unchanged()
        # A background shorthand before background-color (review P3).
        covered = self.original.replace(b"#secondary-action { width:160px; height:52px; padding:12px; border-radius:6px; background-color:#334455;",
                                        b"#secondary-action { width:160px; height:52px; padding:12px; border-radius:6px; background:#000000; background-color:#334455;")
        self.assertNotEqual(covered, self.original)
        self.source.write_bytes(covered)
        row = next(row for row in self.metadata() if row["key"] == "style.secondary-action")
        self.assertIn("`background` also sets `background-color` for `#secondary-action`", row["removals"]["background-color"])
        refused = self.operate(self.request(target="secondary-action", property="background-color", value=""), expected=4)
        self.assertEqual(refused["diagnostic"], row["removals"]["background-color"])
        self.assertEqual(self.source.read_bytes(), covered)
        self.assertEqual(self.catalog.read_bytes(), self.original_catalog)

    def compile_provider(self, properties, replacements):
        manifest = json.loads(self.manifest_path().read_text())
        manifest.pop("editableStyles")
        manifest["editableStyleSources"] = [{"file": "stories.nim", "const": "cardStyles", "properties": properties}]
        self.manifest_path().write_text(json.dumps(manifest))
        source = self.original
        for old, new in replacements:
            self.assertIn(old, source)
            source = source.replace(old, new, 1)
        self.source.write_bytes(source)
        built = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)],
                               env=self.env, capture_output=True, text=True, timeout=70)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        return source, self.catalog.read_bytes()

    def provider_request(self, entry, target, property):
        return {"command": "inspector-edit", "commandId": "native-provider", "expectedRevision": 0,
                "schemaKey": entry["key"], "target": target, "storyId": entry["storyId"],
                "property": property, "value": "", "expectedValue": entry["values"][property],
                "expectedSourceHash": entry["sourceHash"], "viewportWidth": 1440}

    def test_provider_bindings_refuse_overlapping_declarations(self):
        # Review P4: compiled bindings name each explicit declaration as its
        # own owner; another declaration in the rule still sets it.
        source, catalog = self.compile_provider(["padding", "padding-top", "background-color", "width"], [
            (b"#secondary-action { width:160px; height:52px; padding:12px;", b"#secondary-action { width:160px; height:52px; padding:12px; padding-top:3px;"),
            (b"background-color:#334455;", b"background:#000000; background-color:#334455;")])
        entry = next(row for row in self.metadata() if row["elementId"] == "secondary-action")
        self.assertIn("`padding` also sets `padding-top` for `#secondary-action`", entry["removals"]["padding-top"])
        self.assertIn("`padding-top` also sets `padding` for `#secondary-action`", entry["removals"]["padding"])
        self.assertIn("`background` also sets `background-color` for `#secondary-action`", entry["removals"]["background-color"])
        self.assertEqual(entry["removals"]["width"], "")
        for property in ["padding-top", "padding", "background-color"]:
            with self.subTest(property=property):
                refused = self.operate(self.provider_request(entry, "secondary-action", property), expected=4)
                self.assertEqual(refused["diagnostic"], entry["removals"][property])
                self.assertEqual(self.source.read_bytes(), source)
                self.assertEqual(self.catalog.read_bytes(), catalog)

    def test_provider_value_owned_by_a_wider_shorthand_is_refused_not_removed_whole(self):
        # background-color whose current value comes from a later
        # `background` shorthand: removing "it" would remove the whole
        # background declaration (review B2).
        source, catalog = self.compile_provider(["background", "background-color"], [
            (b"#secondary-action { width:160px; height:52px; padding:12px; border-radius:6px; background-color:#334455;",
             b"#secondary-action { width:160px; height:52px; padding:12px; border-radius:6px; background:#445566;")])
        entry = next(row for row in self.metadata() if row["elementId"] == "secondary-action")
        self.assertEqual(entry["sourceDeclarations"]["background-color"]["property"], "background")
        self.assertEqual(entry["removals"]["background-color"],
            "background-color is set by the background declaration; removing it would also remove what it sets for other properties.")
        refused = self.operate(self.provider_request(entry, "secondary-action", "background-color"), expected=4)
        self.assertEqual(refused["diagnostic"], entry["removals"]["background-color"])
        self.assertEqual(self.source.read_bytes(), source)
        self.assertEqual(self.catalog.read_bytes(), catalog)
        self.assertIn(b"background:#445566;", self.source.read_bytes())

    def test_removal_is_refused_at_the_act_unless_exactly_one_declaration_owns_it(self):
        # Stale capability: a human added a second declaration after describe.
        request = self.request(property="width", value="")
        duplicate = self.original.replace(b"#action { width:120px;", b"#action { width:120px; width:121px;")
        self.source.write_bytes(duplicate)
        refused = self.operate(request, expected=4)
        self.assertIn("Source changed", refused["diagnostic"])
        self.assertEqual(self.source.read_bytes(), duplicate)
        # Current capability: refused with the statement, nothing written or built.
        refused = self.operate(self.request(property="width", value=""), expected=4)
        self.assertIn("2 declarations set `width` for `#action`", refused["diagnostic"])
        self.assertEqual(self.source.read_bytes(), duplicate)
        self.assertEqual(self.catalog.read_bytes(), self.original_catalog)
        self.assertFalse((self.project / ".isonim/source-transaction.json").exists())
        self.source.write_bytes(self.original)
        # Absent declaration.
        manifest = json.loads(self.manifest_path().read_text())
        manifest["editableStyles"][0]["properties"].append("opacity")
        self.manifest_path().write_text(json.dumps(manifest))
        refused = self.operate(self.request(property="opacity", value=""), expected=4)
        self.assertIn("There is no `opacity` declaration", refused["diagnostic"])
        self.unchanged()

    def test_undo_of_a_removal_restores_only_the_removed_declaration(self):
        request = self.request(property="height", value="")
        removed = self.operate(request)
        after, after_catalog = self.source.read_bytes(), self.catalog.read_bytes()
        self.assertEqual(after, self.original.replace(b"#action { width:120px; height:48px; ", b"#action { width:120px; ", 1))
        self.assertIn("receipt", removed["sourceEdit"])
        receipt = removed["sourceEdit"]["receipt"]
        forged = [
            dict(receipt, before=receipt["before"].replace("height:48px;", "height:48px; color:red;")),
            dict(receipt, before=receipt["before"] + "echo 1\n"),
            dict(receipt, before=receipt["before"].replace("height:48px;", "height:49px;")),
            dict(receipt, offset=10 ** 6),
            dict(receipt, after="#nothing { }\n"),
            dict(receipt, file="../outside.nim"),
            dict(receipt, file="build_catalog.py"),
            # Review P5: a comment the removal never removed.
            dict(receipt, before=receipt["before"].replace("height:48px;", "height:48px /* injected */;")),
            dict(receipt, before=receipt["before"].replace("height:48px;", "/* injected */ height:48px;")),
            dict(receipt, before=receipt["before"].replace("height:48px;", "height:48px !important;")),
            dict(receipt, unique=not receipt["unique"]),
            dict(receipt, afterHash=hashlib.sha1(b"other").hexdigest().upper()),
        ]
        for index, shape in enumerate(forged):
            with self.subTest(index=index):
                refused = self.undo_removal(request, removed, expected=4, receipt=shape)
                self.assertFalse(refused["ok"])
                self.assertEqual(self.source.read_bytes(), after)
                self.assertEqual(self.catalog.read_bytes(), after_catalog)
                self.assertFalse((self.project / ".isonim/source-transaction.json").exists())
        for key, value in [("offset", "0"), ("unique", "yes"), ("afterHash", 7), ("extra", "x")]:
            with self.subTest(key=key):
                self.undo_removal(request, removed, expected=4, receipt=dict(receipt, **{key: value}))
                self.assertEqual(self.source.read_bytes(), after)
        # The restored value must be the one removed.
        wrong = dict(request, commandId="native-undo", value="49px", expectedValue="",
                     restoreWrite=receipt, expectedSourceHash=self.file_hash())
        self.operate(wrong, expected=4)
        self.assertEqual(self.source.read_bytes(), after)
        # A later edit to the same line: the lines the removal wrote are gone.
        self.operate(self.request(property="width", value="130px"))
        later = self.source.read_bytes()
        refused = self.undo_removal(request, removed, expected=4)
        self.assertIn("Undo refused", refused["diagnostic"])
        self.assertEqual(self.source.read_bytes(), later)
        # Undoing that edit makes the receipt exact again.
        self.operate(self.request(property="width", value="120px"))
        self.assertEqual(self.source.read_bytes(), after)
        self.assertTrue(self.undo_removal(request, removed)["ok"])
        self.assertEqual(self.source.read_bytes(), self.original)

    def store(self):
        return self.project / ".isonim/removal-receipts.json"

    def test_receipt_store_is_part_of_the_removal_and_its_undo(self):
        request = self.request(property="height", value="")
        removed = self.operate(request)
        records = json.loads(self.store().read_text())
        self.assertEqual([row["receipt"] for row in records], [removed["sourceEdit"]["receipt"]])
        self.assertTrue(self.undo_removal(request, removed)["ok"])
        self.assertEqual(json.loads(self.store().read_text()), [])
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_an_unreadable_receipt_store_refuses_removal_and_undo_before_any_write(self):
        # Review C1: the store is validated before the transaction writes.
        for label, prepare in [("corrupt", lambda: self.store().write_text("{not json")),
                               ("object", lambda: self.store().write_text("{}")),
                               ("directory", lambda: self.store().mkdir())]:
            with self.subTest(store=label):
                prepare()
                refused = self.operate(self.request(property="height", value=""), expected=4)
                self.assertIn("removal receipt store", refused["diagnostic"])
                self.assertIn("Nothing was changed", refused["diagnostic"])
                self.unchanged()
                if self.store().is_dir(): self.store().rmdir()
                else: self.store().unlink()
        # A genuine removal, then the store breaks: its undo is refused too.
        request = self.request(property="height", value="")
        removed = self.operate(request)
        after, after_catalog = self.source.read_bytes(), self.catalog.read_bytes()
        self.store().write_text("{not json")
        refused = self.undo_removal(request, removed, expected=4)
        self.assertIn("removal receipt store", refused["diagnostic"])
        self.assertEqual(self.source.read_bytes(), after)
        self.assertEqual(self.catalog.read_bytes(), after_catalog)

    def test_a_receipt_store_write_that_fails_rolls_the_removal_back(self):
        # Review C1: the store cannot be written after validation (here the
        # project's own build makes its path a directory, as a full disk or a
        # permission change would make the write fail). The source and catalog
        # the transaction already wrote are restored and the act is refused.
        manifest = json.loads(self.manifest_path().read_text())
        manifest["build"] = ["sh", "-c", "mkdir -p .isonim/removal-receipts.json/blocked && exec python3 build_catalog.py"]
        self.manifest_path().write_text(json.dumps(manifest))
        refused = self.operate(self.request(property="height", value=""), expected=4)
        self.assertIn("could not be written", refused["diagnostic"])
        self.assertIn("source and catalog were restored", refused["diagnostic"])
        self.unchanged()
        # An ordinary edit with the same build is unaffected by the store.
        self.store().joinpath("blocked").rmdir(); self.store().rmdir()
        self.assertTrue(self.operate(self.request(property="width", value="130px"))["ok"])
        self.assertIn(b"width:130px;", self.source.read_bytes())

    def test_undo_cannot_insert_a_declaration_no_removal_removed(self):
        # Review P6: a well-formed receipt the worker never issued, for an
        # allowed property with a valid value, is refused unchanged.
        manifest = json.loads(self.manifest_path().read_text())
        manifest["editableStyles"][0]["properties"].append("opacity")
        self.manifest_path().write_text(json.dumps(manifest))
        current = self.source.read_bytes()
        text = current.decode()
        line = self.ACTION_LINE.decode()
        receipt = {"file": "stories.nim", "offset": text.index(line),
                   "before": line.replace("color:#FFFFFF;", "color:#FFFFFF; opacity:0.5;"), "after": line,
                   "unique": True, "afterHash": hashlib.sha1(current).hexdigest().upper()}
        request = {"command": "inspector-edit", "commandId": "never-removed", "expectedRevision": 0,
                   "schemaKey": "style.action", "target": "action", "storyId": "Card / default ready",
                   "property": "opacity", "value": "0.5", "expectedValue": "", "restoreWrite": receipt,
                   "expectedSourceHash": hashlib.sha1(current).hexdigest().upper(), "viewportWidth": 1440}
        refused = self.operate(request, expected=4)
        self.assertIn("was not issued by a removal", refused["diagnostic"])
        self.unchanged()
        # A genuine receipt is spent by its undo: replaying it is refused too.
        removal = self.request(property="height", value="")
        removed = self.operate(removal)
        self.assertTrue(self.undo_removal(removal, removed)["ok"])
        self.assertEqual(self.source.read_bytes(), self.original)
        replay = self.undo_removal(removal, removed, expected=4)
        self.assertIn("was not issued by a removal", replay["diagnostic"])
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_provider_bindings_state_removal_per_declaration_and_shared_rules_restore_exactly(self):
        manifest = json.loads(self.manifest_path().read_text())
        manifest.pop("editableStyles")
        manifest["editableStyleSources"] = [{"file": "stories.nim", "const": "cardStyles",
            "properties": ["padding", "width", "--brand", "background-color"]}]
        self.manifest_path().write_text(json.dumps(manifest))
        source = self.original.replace(b'const cardStyles* = """\n', b'const cardStyles* = """\n:root { --brand:#224466; }\n', 1) \
            .replace(b"#reused-card { width:110px; height:40px; background-color:#224466; }",
                     b"#reused-card { width:110px; height:40px; background-color:var(--brand); }")
        self.source.write_bytes(source)
        built = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)],
                               env=self.env, capture_output=True, text=True, timeout=70)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        rows = self.metadata()
        self.assertTrue(rows and all("removals" in row for row in rows))
        shared = next(row for row in rows if row["elementId"] == "reused" and row["scope"] == "shared-class"
                      and row["storyId"] == "Card / default ready")
        token = next(row for row in rows if row["elementId"] == "reused" and row["scope"] == "semantic-token")
        secondary = next(row for row in rows if row["elementId"] == "secondary-action")
        self.assertEqual(shared["properties"], ["width"])
        self.assertEqual(shared["removals"]["width"], "")
        self.assertIn("design token --brand", token["removals"]["background-color"])
        self.assertEqual(secondary["removals"]["padding"], "")
        self.assertIn("padding shorthand", secondary["removals"]["padding-top"])
        catalog_before = self.catalog.read_bytes()
        for target, property, entry in [("secondary-action", "padding-top", secondary),
                                        ("reused", "background-color", token)]:
            with self.subTest(property=property):
                request = {"command": "inspector-edit", "commandId": "native-refused", "expectedRevision": 0,
                           "schemaKey": entry["key"], "target": target, "storyId": entry["storyId"],
                           "property": property, "value": "", "expectedValue": entry["values"][property],
                           "expectedSourceHash": entry["sourceHash"], "viewportWidth": 1440}
                refused = self.operate(request, expected=4)
                self.assertEqual(refused["diagnostic"], entry["removals"][property])
                self.assertEqual(self.source.read_bytes(), source)
                self.assertEqual(self.catalog.read_bytes(), catalog_before)
        # The shared rule's only bound declaration: after Reset the binding
        # keeps offering it with no value (nothing left to remove), so it can
        # be set again (isonim-pm issue 2026-10-16-compiled-bindings-cannot-
        # be-re-set-after-reset-removes-their-last-declaration), and undo
        # still restores exactly that line.
        request = {"command": "inspector-edit", "commandId": "native-shared", "expectedRevision": 0,
                   "schemaKey": shared["key"], "target": "reused", "storyId": shared["storyId"],
                   "property": "width", "value": "", "expectedValue": "110px",
                   "expectedSourceHash": shared["sourceHash"], "viewportWidth": 1440}
        removed = self.operate(request)
        self.assertEqual(self.source.read_bytes(), source.replace(b"#reused-card { width:110px; ", b"#reused-card { ", 1))
        kept = [row for row in removed["editableStyles"] if row["key"] == shared["key"]]
        self.assertEqual([row["values"] for row in kept], [{"width": ""}])
        kept = kept[0]
        self.assertIn("There is no `width` declaration", kept["removals"]["width"])
        restored = self.undo_removal(request, removed)
        self.assertTrue(restored["ok"], restored)
        self.assertEqual(self.source.read_bytes(), source)
        self.assertTrue(any(row["key"] == shared["key"] and row["values"]["width"] == "110px"
                            for row in restored["editableStyles"]))

class NativeReSetAndSelectorListTests(InspectorSourceTransactionTests):
    """Re-set after Reset for compiled bindings, and selector-list rules.

    isonim-pm issues 2026-10-16-compiled-bindings-cannot-be-re-set-after-
    reset-removes-their-last-declaration and 2026-10-16-selector-list-rules-
    are-admitted-for-edit-and-removal. Editor spec "Universal Patterns": Reset
    is "written and undoable like any edit", and after it the property can be
    set again (a typed value is inserted into the rule it was removed from);
    "Saving": an edit changes exactly the one owning declaration, so a
    declaration in a rule shared by a selector list is refused with that
    reason. The same real worker, files and project compiler as above; no
    mock. Inherits fixture and helpers only (inherited cases filtered below)."""

    file_hash = NativeDeclarationRemovalTests.file_hash
    undo_removal = NativeDeclarationRemovalTests.undo_removal
    manifest_path = NativeDeclarationRemovalTests.manifest_path
    compile_provider = NativeDeclarationRemovalTests.compile_provider

    def one(self, rows, matches, what):
        found = [row for row in rows if matches(row)]
        self.assertEqual(len(found), 1, what + ": " + json.dumps(rows))
        return found[0]

    def edit(self, entry, target, property, value, expected):
        return {"command": "inspector-edit", "commandId": "native-re-set", "expectedRevision": 0,
                "schemaKey": entry["key"], "target": target, "storyId": entry["storyId"],
                "property": property, "value": value, "expectedValue": expected,
                "expectedSourceHash": entry["sourceHash"], "viewportWidth": 1440}

    def test_a_compiled_binding_is_re_set_after_reset_removes_its_last_declaration(self):
        source, _ = self.compile_provider(["width"], [])
        rows = self.metadata()
        shared = self.one(rows, lambda row: row["elementId"] == "reused" and row["storyId"] == "Card / default ready", "the reused binding")
        self.assertEqual(shared["values"], {"width": "110px"})
        removal = self.edit(shared, "reused", "width", "", "110px")
        removed = self.operate(removal)
        reset = source.replace(b"#reused-card { width:110px; ", b"#reused-card { ", 1)
        self.assertEqual(self.source.read_bytes(), reset)
        # Still offered, with nothing to remove, under the same key.
        offered = self.one(self.metadata(), lambda row: row["key"] == shared["key"], "the binding after Reset")
        self.assertEqual(offered["values"], {"width": ""})
        self.assertEqual(offered["selector"], "#reused-card")
        self.assertIn("There is no `width` declaration", offered["removals"]["width"])
        # Set again: one declaration inserted into the rule it came from.
        set_request = self.edit(offered, "reused", "width", "150px", "")
        written = self.operate(set_request)
        self.assertTrue(written["ok"], written)
        again = reset.replace(b"#reused-card { height:40px; background-color:#224466; }",
                              b"#reused-card { height:40px; background-color:#224466; width:150px; }", 1)
        self.assertNotEqual(again, reset)
        self.assertEqual(self.source.read_bytes(), again)
        card = next(story["documentHtml"] for story in written["catalog"]["stories"] if story["group"] == "Card")
        self.assertIn("width:150px", card)
        now = self.one(written["editableStyles"], lambda row: row["key"] == shared["key"], "the binding after the set")
        self.assertEqual(now["values"], {"width": "150px"})
        # Undo the set (the browser removes what it inserted), then the Reset.
        unset = self.edit(now, "reused", "width", "", "150px")
        self.assertTrue(self.operate(unset)["ok"])
        self.assertEqual(self.source.read_bytes(), reset)
        restored = self.undo_removal(removal, removed)
        self.assertTrue(restored["ok"], restored)
        self.assertEqual(self.source.read_bytes(), source)
        self.assertTrue(any(row["key"] == shared["key"] and row["values"] == {"width": "110px"}
                            for row in restored["editableStyles"]))

    def test_a_compiled_re_set_is_offered_only_where_the_rule_alone_would_own_it(self):
        source, _ = self.compile_provider(["width"], [])
        shared = self.one(self.metadata(), lambda row: row["elementId"] == "reused" and row["storyId"] == "Card / default ready", "the reused binding")
        self.operate(self.edit(shared, "reused", "width", "", "110px"))
        reset = self.source.read_bytes()
        # Another rule that sets width for the element (here a conditional
        # one for the same selector) decides it: not offered, and a set is
        # refused with nothing written.
        conditional = reset.replace(b'#secondary-action {', b'@media (max-width: 600px) { #reused-card { width:90px; } }\n#secondary-action {', 1)
        self.assertNotEqual(conditional, reset)
        self.source.write_bytes(conditional)
        self.assertFalse(any(row["key"] == shared["key"] for row in self.metadata()))
        refused = self.operate(self.edit(dict(shared, sourceHash=self.file_hash()), "reused", "width", "150px", ""), expected=4)
        self.assertIn("Unsupported editable source schema", refused["diagnostic"])
        self.assertEqual(self.source.read_bytes(), conditional)
        # Another selector's rule that sets width for the element (here a
        # type selector) decides it too: not offered.
        typed = reset.replace(b'#secondary-action {', b'button { width:90px; }\n#secondary-action {', 1)
        self.assertNotEqual(typed, reset)
        self.source.write_bytes(typed)
        self.assertFalse(any(row["key"] == shared["key"] for row in self.metadata()))
        # Without another owner it is offered again; once the project no
        # longer opts width in, it is not (height, still opted in, is).
        self.source.write_bytes(reset)
        rows = [row for row in self.metadata() if row["key"] == shared["key"]]
        self.assertEqual([row["values"] for row in rows], [{"width": ""}])
        manifest = json.loads(self.manifest_path().read_text())
        manifest["editableStyleSources"][0]["properties"] = ["height"]
        self.manifest_path().write_text(json.dumps(manifest))
        rows = [row for row in self.metadata() if row["key"] == shared["key"]]
        self.assertEqual([row["values"] for row in rows], [{"height": "40px"}])

    def test_a_compiled_re_offer_outlives_the_receipt_undo_cap(self):
        # Review R1: the re-offer lasts until the removal is undone, not
        # while its receipt is among the last 64. 65 later removals (each
        # set back, none undone) evict the Reset's receipt from the undo
        # history; width is still offered and can be set.
        source, _ = self.compile_provider(["width"], [])
        shared = self.one(self.metadata(), lambda row: row["elementId"] == "reused" and row["storyId"] == "Card / default ready", "the reused binding")
        self.operate(self.edit(shared, "reused", "width", "", "110px"))
        reset = self.source.read_bytes()
        for index in range(65):
            action = self.one(self.metadata(), lambda row: row["elementId"] == "action", "the action binding")
            self.operate(self.edit(action, "action", "width", "", "120px"))
            again = self.one(self.metadata(), lambda row: row["elementId"] == "action", "the action binding after Reset")
            self.assertEqual(again["values"], {"width": ""})
            self.operate(self.edit(again, "action", "width", "120px", ""))
        self.assertEqual(self.source.read_bytes(), reset.replace(b"#action { width:120px; ", b"#action { ", 1)
                         .replace(b"color:#FFFFFF; }\n#reused-card", b"color:#FFFFFF; width:120px; }\n#reused-card", 1))
        store = json.loads((self.project / ".isonim/removal-receipts.json").read_text())
        receipts = [row for row in store if "receipt" in row]
        self.assertEqual(len(receipts), 64)
        self.assertFalse(any(row["schemaKey"] == shared["key"] for row in receipts))
        offered = self.one(self.metadata(), lambda row: row["key"] == shared["key"], "the reused binding after 65 later removals")
        self.assertEqual(offered["values"], {"width": ""})
        self.assertTrue(self.operate(self.edit(offered, "reused", "width", "150px", ""))["ok"])
        self.assertIn(b"#reused-card { height:40px; background-color:#224466; width:150px; }", self.source.read_bytes())

    def test_a_compiled_re_offer_reaches_every_element_its_rule_matches(self):
        # Review: every element the shared single-selector rule matches keeps
        # the offer, each under every condition: the rule matches it, its
        # inline style does not set the property, the project opts it in.
        target = b'button(id = target, `data-isonim-element-id` = target): text "Continue"'
        chip_target = b'button(id = target, `data-isonim-element-id` = target, class = "chip"): text "Continue"'
        secondary = b'button(id = "secondary-action", `data-isonim-element-id` = "secondary-action"): text "Review"'
        chip_secondary = b'button(id = "secondary-action", `data-isonim-element-id` = "secondary-action", class = "chip"): text "Review"'
        source, _ = self.compile_provider(["opacity"], [
            (b'const cardStyles* = """\n', b'const cardStyles* = """\n.chip { opacity:0.5; }\n'),
            (target, chip_target), (secondary, chip_secondary)])
        chips = lambda: {(row["storyId"], row["elementId"]): row for row in self.metadata() if row["selector"] == ".chip"}
        before = chips()
        self.assertEqual(sorted(before), [("Alternate / default ready", "alternate-action"),
                                          ("Card / default ready", "action"), ("Card / default ready", "secondary-action")])
        self.assertTrue(all(row["values"] == {"opacity": "0.5"} for row in before.values()))
        action = before[("Card / default ready", "action")]
        removal = self.edit(action, "action", "opacity", "", "0.5")
        removed = self.operate(removal)
        reset = self.source.read_bytes()
        self.assertIn(b".chip { }", reset)
        after = chips()
        self.assertEqual(sorted(after), sorted(before))
        self.assertTrue(all(row["values"] == {"opacity": ""} for row in after.values()))
        self.assertEqual({key: row["key"] for key, row in after.items()}, {key: row["key"] for key, row in before.items()})
        # Set from another element sharing the rule: inserted into .chip.
        other = after[("Card / default ready", "secondary-action")]
        self.assertTrue(self.operate(self.edit(other, "secondary-action", "opacity", "0.7", ""))["ok"])
        self.assertIn(b".chip { opacity:0.7; }", self.source.read_bytes())
        self.operate(self.edit(chips()[("Card / default ready", "secondary-action")], "secondary-action", "opacity", "", "0.7"))
        self.assertEqual(self.source.read_bytes(), reset)
        def rebuild(text):
            self.source.write_bytes(text)
            built = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)],
                                   env=self.env, capture_output=True, text=True, timeout=70)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        # The rule no longer matches an element: that element is not offered.
        rebuild(reset.replace(chip_secondary, secondary, 1))
        self.assertEqual(sorted(chips()), [("Alternate / default ready", "alternate-action"), ("Card / default ready", "action")])
        # An inline style that sets the property owns it: not offered.
        rebuild(reset.replace(chip_target, b'button(id = target, `data-isonim-element-id` = target, class = "chip", style = "opacity:1"): text "Continue"', 1))
        self.assertEqual(sorted(chips()), [("Card / default ready", "secondary-action")])
        # The project stops opting the property in: offered nowhere.
        rebuild(reset)
        self.assertEqual(len(chips()), 3)
        manifest = json.loads(self.manifest_path().read_text())
        manifest["editableStyleSources"][0]["properties"] = ["width"]
        self.manifest_path().write_text(json.dumps(manifest))
        self.assertEqual(chips(), {})
        # Undo of the Reset restores the line and ends the re-offer record.
        manifest["editableStyleSources"][0]["properties"] = ["opacity"]
        self.manifest_path().write_text(json.dumps(manifest))
        self.assertTrue(self.undo_removal(removal, removed)["ok"])
        self.assertEqual(self.source.read_bytes(), source)
        store = json.loads((self.project / ".isonim/removal-receipts.json").read_text())
        self.assertFalse(any("offer" in row and "receipt" not in row for row in store), store)

    def test_a_selector_list_rule_is_refused_for_edit_and_removal(self):
        listed = self.original.replace(b"#secondary-action { width:160px;", b"#secondary-action, .ghost { width:160px;", 1)
        self.assertNotEqual(listed, self.original)
        self.source.write_bytes(listed)
        built = subprocess.run(["python3", str(REPO / "tools/build_source_catalog.py"), str(self.project)],
                               env=self.env, capture_output=True, text=True, timeout=70)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        catalog = self.catalog.read_bytes()
        reason = ("`#secondary-action` is styled here by the selector list `#secondary-action, .ghost`; "
                  "changing `width` there would change every selector in the list. Edit the stylesheet directly.")
        row = self.one(self.metadata(), lambda row: row["key"] == "style.secondary-action", "the explicit entry")
        self.assertEqual(row.get("edits", {}).get("width"), reason)
        self.assertEqual(row["removals"]["width"], reason)
        self.assertEqual(set(row.get("edits", {})), set(row["values"]))
        # Every other entry states nothing against its edits.
        self.assertTrue(all(not reason for other in self.metadata() if other["key"] != "style.secondary-action"
                            for reason in other.get("edits", {}).values()))
        for value in ["170px", ""]:
            with self.subTest(value=value):
                refused = self.operate(self.edit(row, "secondary-action", "width", value, "160px"), expected=4)
                self.assertEqual(refused["diagnostic"], reason)
                self.assertEqual(self.source.read_bytes(), listed)
                self.assertEqual(self.catalog.read_bytes(), catalog)
                self.assertFalse((self.project / ".isonim/source-transaction.json").exists())
        # Compiled bindings state the same for the list member's declarations.
        self.compile_provider(["width"], [(b"#secondary-action { width:160px;", b"#secondary-action, .ghost { width:160px;")])
        compiled = self.one(self.metadata(), lambda row: row["elementId"] == "secondary-action", "the compiled binding")
        self.assertEqual(compiled.get("edits", {}).get("width"), reason)
        self.assertEqual(compiled["removals"]["width"], reason)
        before = self.source.read_bytes()
        refused = self.operate(self.edit(compiled, "secondary-action", "width", "170px", "160px"), expected=4)
        self.assertEqual(refused["diagnostic"], reason)
        self.assertEqual(self.source.read_bytes(), before)

for _name in list(vars(InspectorSourceTransactionTests)):
    if _name.startswith("test_") and _name not in vars(NativeReSetAndSelectorListTests):
        setattr(NativeReSetAndSelectorListTests, _name, None)

for _name in list(vars(InspectorSourceTransactionTests)):
    if _name.startswith("test_") and _name not in vars(NativeDeclarationRemovalTests):
        setattr(NativeDeclarationRemovalTests, _name, None)

if __name__ == "__main__":
    unittest.main()
