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

if __name__ == "__main__":
    unittest.main()
