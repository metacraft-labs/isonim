#!/usr/bin/env python3
"""Compile the real Tailwind loader in an isolated production-source layout.

Copies the repository's actual Nim sources, never its generated build directory
or compiler configuration. All compiler outputs/caches stay under build/. This
makes default-map absence real even after build-tailwind has populated the
checkout. C binaries, JS under actual Node, and NimScript execute assertions
about map flags and exact resolved styles. The custom-class component also uses
the real DSL/SSR implementation, without a renderer double.

The small JSON objects are loader input fixtures, not fake extraction results.
The separate real-extractor golden and variant/unit suites remain necessary.
The common class exercises C/JS/NimScript map contracts on every host, including
Windows, without requiring POSIX permissions or symlink privileges. A separate
class is registered only on POSIX hosts for permission and symlink semantics;
those fixtures must demonstrably deny the intended operation or fail, never
skip. Both classes run on Linux/macOS. Reports name the actual platform/scopes;
a common-suite run on Windows does not qualify the POSIX filesystem controls.
Existing empty-map and explicit-missing-path target differences are intentional
compatibility checks, not new error-policy requirements.
Windows compiler-path forms are also checked as pure argument data using real
host Nim; those assertions are not a Windows process or toolchain simulation.
JS/NimScript must preserve read failures for named links, including denied and
absent targets under unlistable parents. The metadata query uses the selected
real compiler. ISONIM_TAILWIND_TEST_NIM may select another actual compiler for
minimum-version qualification; it never substitutes a fake compiler.
"""
import hashlib
import json
import os
import re
from contextlib import contextmanager
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ("c", "js", "e")
REPORTS = []
PROBE = """import isonim/dsl/tailwind
const expectedHas {.booldefine.} = false
const expectedColor {.strdefine.} = ""
static:
  doAssert hasTailwindStyles == expectedHas
  doAssert expandTailwindClassesCompileTime("custom-class").len == 0
  when expectedColor.len > 0:
    doAssert expandTailwindClassesCompileTime("loader-color") ==
      @[("color", expectedColor)]
    doAssert parseTailwindClass("loader-color") == @[("color", expectedColor)]
  else:
    doAssert expandTailwindClassesCompileTime("loader-color").len == 0
echo "loader assertions passed"
"""
CONSUMER = """import isonim/dsl/ui
import isonim/ssr/escape
let html = ui:
  tdiv(class = "custom-class"):
    text "Hello"
doAssert html == "<div class=\\"custom-class\\">Hello</div>"
echo html
"""
QUOTE_FORMS = r'''include isonim/dsl/tailwind
static:
  doAssert quoteCompilerCommand("/compiler space/nim", ["e"]) == "'/compiler space/nim' e"
  let drive = r"C:\Program Files\Nim\nim.exe"
  doAssert quoteCompilerCommand(drive, ["e"]) == "\"" & drive & "\" e"
  let unc = r"\\server\share space\nim.exe"
  doAssert quoteCompilerCommand(unc, ["e"]) == "\"" & unc & "\" e"
  for invalid in ["", "nim", "C:nim.exe", r"\root-relative\nim.exe", r"\\server\share"]:
    var refused = false
    try: discard quoteCompilerCommand(invalid, ["e"])
    except IOError: refused = true
    doAssert refused
echo "native quoting forms passed"
'''


class TailwindLoaderBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.nim = shutil.which(os.environ.get("ISONIM_TAILWIND_TEST_NIM", "nim"))
        cls.node = shutil.which("node")
        if not cls.nim or not cls.node:
            raise RuntimeError("Tailwind loader tests require real nim and node on PATH")
        (ROOT / "build").mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix="tailwind-loader-", dir=ROOT / "build")
        cls.work = Path(cls.temp.name)
        source_name = "production 'quote' $dollar `tick` ; λ"
        if os.name == "posix":
            source_name += ' "double"'
        cls.export = cls.work / source_name
        cls.artifacts = cls.work / "artifacts"
        cls.artifacts.mkdir()
        cls.source_hashes = {}
        for source in sorted((ROOT / "src").rglob("*.nim")):
            relative = source.relative_to(ROOT)
            destination = cls.export / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            cls.source_hashes[str(relative)] = hashlib.sha256(source.read_bytes()).hexdigest()
        cls.map_path = cls.export / "build/tailwind-styles.json"
        cls.loader_path = cls.export / "src/isonim/dsl/tailwind.nim"
        cls.records = []
        cls.counter = 0
        cls.versions = {
            tool: subprocess.check_output([binary, "--version"], text=True, encoding="utf-8")
            for tool, binary in [("nim", cls.nim), ("node", cls.node)]
        }
        identity = subprocess.check_output([
            cls.nim, "e", "--hints:off", "--warnings:off", "--skipUserCfg:on",
            "--skipParentCfg:on", "--skipProjCfg:on",
            "--eval:import std/[os, compilesettings]; echo getCurrentCompilerExe(); "
            "echo querySetting(SingleValueSetting.libPath)"], cwd=cls.work,
            text=True, encoding="utf-8").splitlines()
        if len(identity) != 2 or not all(Path(path).is_absolute() for path in identity):
            raise AssertionError("compiler must report its actual executable and selected library: " + repr(identity))
        cls.selected_executable, cls.selected_library = map(Path, identity)

    @classmethod
    def tearDownClass(cls):
        report = {"nim": cls.nim, "node": cls.node, "versions": cls.versions,
                  "selectedExecutable": str(cls.selected_executable),
                  "selectedLibrary": str(cls.selected_library),
                  "compilerSha256": hashlib.sha256(cls.selected_executable.read_bytes()).hexdigest(),
                  "sourceSha256": cls.source_hashes, "commands": cls.records,
                  "scope": cls.__name__}
        REPORTS.append(report)
        assert all(entry["sourceSha256"] == cls.source_hashes for entry in REPORTS)
        combined = dict(report, platform=os.name,
                        scopes=[entry["scope"] for entry in REPORTS],
                        commands=[row for entry in REPORTS for row in entry["commands"]])
        del combined["scope"]
        (ROOT / "build/tailwind-loader-results.json").write_text(json.dumps(combined, indent=2) + "\n", encoding="utf-8")
        cls.temp.cleanup()

    def setUp(self):
        if self.map_path.parent.is_dir():
            shutil.rmtree(self.map_path.parent)
        elif self.map_path.parent.is_symlink() or self.map_path.parent.exists():
            self.map_path.parent.unlink()

    def invoke(self, argv, environment=None):
        started = time.monotonic()
        result = subprocess.run(argv, cwd=self.export, text=True, encoding="utf-8", stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=90,
                                env=None if environment is None else dict(os.environ, **environment))
        self.records.append({"argv": argv, "exitCode": result.returncode,
                             "seconds": round(time.monotonic() - started, 3),
                             "output": result.stdout, "explicitEnvironment": environment or {},
                             "loaderSha256": hashlib.sha256(self.loader_path.read_bytes()).hexdigest()})
        return result

    def compile(self, target, *, has=False, color="", override=None, error=None,
                consumer=False, compiler=None, environment=None, extra_args=(),
                source_text=None, expected_output=None):
        type(self).counter += 1
        name = f"probe_{self.counter}"
        source = self.artifacts / (name + (".nims" if target == "e" else ".nim"))
        source.write_text(source_text if source_text is not None else CONSUMER if consumer else PROBE, encoding="utf-8")
        output = self.artifacts / (name + (".js" if target == "js" else ".exe" if os.name == "nt" else ""))
        # Parent/user configuration must not route imports back to this checkout.
        # System configuration still supplies the real wrapped compiler/toolchain.
        args = [str(compiler or self.nim), target, "--hints:off", "--skipParentCfg:on",
                "--skipProjCfg:on", "--skipUserCfg:on",
                # Nim's path-option substitution is separate from OS argv
                # quoting; $$ represents the actual source path's literal $.
                "--path:" + str(self.export / "src").replace("$", "$$"),
                "--nimcache:" + str(self.artifacts / (name + "_cache")).replace("$", "$$")]
        if target != "e":
            args += ["--out:" + str(output).replace("$", "$$")]
        if target == "js":
            args += ["-d:nodejs"]
        if consumer:
            # The full DSL imports the framework's platform dependency. Keep
            # it explicit while parent/project/user configuration is disabled.
            platform_source = Path(os.environ.get("NIM_EVERYWHERE_SRC", ROOT.parent / "nim-everywhere"))
            self.assertTrue((platform_source / "src/nim_everywhere/platform.nim").is_file())
            args += ["--path:" + str(platform_source / "src").replace("$", "$$")]
        if not consumer:
            args += ["-d:expectedHas=" + str(has).lower(), "-d:expectedColor=" + color]
        if override is not None:
            args += ["-d:tailwindStylesPathOverride=" + str(override)]
        result = self.invoke(args + list(extra_args) + [str(source)], environment)
        if error is not None:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertRegex(result.stdout, error)
            return
        self.assertEqual(result.returncode, 0, result.stdout)
        if target != "e":
            result = self.invoke([self.node, str(output)] if target == "js" else [str(output)], environment)
            self.assertEqual(result.returncode, 0, result.stdout)
        expected = '<div class="custom-class">Hello</div>' if consumer else "loader assertions passed"
        self.assertEqual(result.stdout.strip(), expected_output or expected)

    def write_map(self, contents, override=False):
        path = self.work / "override.json" if override else self.map_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    @contextmanager
    def loader_fault(self, *, program=None, replacement=None):
        # Narrow fault injection into a disposable real-source copy. The actual
        # selected compiler still executes the child (or refuses invalid input);
        # no fake executable, successful stub, or production test switch is used.
        original = self.loader_path.read_bytes()
        source = original.decode("utf-8")
        if program is not None:
            pattern = r'  const tailwindMetadataProgram = """.*?"""'
            modified, count = re.subn(pattern,
                lambda _: '  const tailwindMetadataProgram = """\n' + program + '\n"""',
                source, flags=re.S)
            self.assertEqual(count, 1)
        else:
            before, after = replacement
            self.assertEqual(source.count(before), 1)
            modified = source.replace(before, after)
        self.loader_path.write_bytes(modified.encode("utf-8"))
        try:
            yield
        finally:
            self.loader_path.write_bytes(original)
            self.assertEqual(self.loader_path.read_bytes(), original)


class TailwindLoaderCommonTests(TailwindLoaderBase):
    def test_fault_injection_preserves_crlf_source_bytes(self):
        # A real source layout with different line endings tests byte-preserving
        # fault cleanup on any host; it does not simulate a Windows compiler.
        original = self.loader_path.read_bytes()
        crlf = original.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        self.loader_path.write_bytes(crlf)
        try:
            for target in ("js", "e"):
                self.compile(target)
            with self.loader_fault(program='{.error: "CRLF child failure control".}'):
                for target in ("js", "e"):
                    self.compile(target, error=r"(?s)Tailwind metadata query failed:.*CRLF child failure control")
            self.assertEqual(self.loader_path.read_bytes(), crlf)
            for target in ("js", "e"):
                self.compile(target)
        finally:
            self.loader_path.write_bytes(original)
            self.assertEqual(self.loader_path.read_bytes(), original)

    def test_native_absolute_compiler_quoting_forms(self):
        for target in ("js", "e"):
            self.compile(target, source_text=QUOTE_FORMS, expected_output="native quoting forms passed")

    def test_helper_failure_and_bad_protocol_are_errors(self):
        cases = [('{.error: "metadata child failure control".}', "Tailwind metadata query failed"),
                 ('proc query(path: string) = echo "unexpected response"', "Invalid Tailwind metadata response"),
                 ('proc query(path: string) =\n  echo "isonim-tailwind-map-v1:absent"\n  echo "extra"',
                  "Invalid Tailwind metadata response")]
        for program, message in cases:
            with self.loader_fault(program=program):
                for target in ("js", "e"):
                    with self.subTest(target=target, program=program):
                        self.compile(target, error=message)

    def test_readable_default_and_explicit_maps_do_not_run_helper(self):
        override = self.write_map('{"loader-color":{"color":"#abcdef"}}', override=True)
        with self.loader_fault(program='{.error: "helper must not run".}'):
            self.write_map('{"loader-color":{"color":"#123456"}}')
            for target in ("js", "e"):
                self.compile(target, has=True, color="#123456")
            self.map_path.unlink()
            for target in ("js", "e"):
                self.compile(target, has=True, color="#abcdef", override=override)

    def test_unknown_compiler_path_refuses_before_query(self):
        with self.loader_fault(replacement=(
                'quoteCompilerCommand(getCurrentCompilerExe(), [',
                'quoteCompilerCommand("relative/nim", [')):
            for target in ("js", "e"):
                self.compile(target, error="Unknown absolute Nim compiler path")

    def test_helper_ignores_consumer_project_and_parent_config(self):
        configs = [self.work / "config.nims", self.export / "config.nims",
                   self.artifacts / "config.nims", self.loader_path.parent / "config.nims"]
        for path in configs:
            path.write_text('{.error: "consumer config must not run".}\n', encoding="utf-8")
        try:
            for target in ("js", "e"):
                self.compile(target)
            with self.loader_fault(replacement=(
                    '"--skipProjCfg:on",', '')):
                for target in ("js", "e"):
                    self.compile(target, error=r"(?s)Tailwind metadata query failed:.*consumer config must not run")
            # With only parent suppression removed, the repository's outer
            # config may run before the owned sentinel. Name that exact file
            # as a second valid witness; an unrelated helper error is not one.
            owner_config = r"[\\/]".join(
                re.escape(part) for part in str(ROOT / "config.nims").replace("\\", "/").split("/"))
            witness = r"(?is)Tailwind metadata query failed:.*(?:" + owner_config + r"|consumer config must not run)"
            with self.loader_fault(replacement=('"--skipParentCfg:on",', '')):
                for target in ("js", "e"):
                    self.compile(target, error=witness)
        finally:
            for path in configs:
                path.unlink()

    def test_explicit_selected_library_reaches_actual_child(self):
        selected = self.work / "selected library $dollar"
        shutil.copytree(self.selected_library, selected)
        expected = json.dumps(str(selected), ensure_ascii=False)
        extra_args = ["--lib:" + str(selected).replace("$", "$$")]
        # Instrument only the real query's entry point to verify selected-lib
        # propagation; its metadata classifier and actual child remain intact.
        replacement = ('proc query(path: string) =',
                       'import std/compilesettings\nproc query(path: string) =\n'
                       '  if querySetting(SingleValueSetting.libPath) != ' + expected + ':\n'
                       '    raise newException(IOError, "selected library was not forwarded")')
        with self.loader_fault(replacement=replacement):
            for target in ("js", "e"):
                self.compile(target, extra_args=extra_args)
            with self.loader_fault(replacement=(
                    '"--lib:" & library.replace("$", "$$"),', '')):
                for target in ("js", "e"):
                    self.compile(target, extra_args=extra_args,
                                 error=r"(?s)Tailwind metadata query failed:.*selected library was not forwarded")

    def test_absent_default_with_and_without_build_directory(self):
        for layout in ("no-build", "empty-build", "populated-build"):
            if layout == "empty-build":
                self.map_path.parent.mkdir()
            elif layout == "populated-build":
                (self.map_path.parent / "unrelated.txt").write_text("not a style map", encoding="utf-8")
            self.assertFalse(self.map_path.exists())
            for target in TARGETS:
                with self.subTest(layout=layout, target=target):
                    self.compile(target)

    def test_custom_class_dsl_consumer_needs_no_default_map(self):
        self.assertFalse(self.map_path.parent.exists())
        for target in ("c", "js"):
            with self.subTest(target=target):
                self.compile(target, consumer=True)

    def test_empty_map_flags_preserve_existing_target_semantics(self):
        for contents in ("{}", "{}\n"):
            for overridden in (False, True):
                path = self.write_map(contents, override=overridden)
                for target in TARGETS:
                    with self.subTest(contents=repr(contents), override=overridden, target=target):
                        self.compile(target, has=(target == "c" or contents != "{}"),
                                     override=path if overridden else None)

    def test_nonempty_default_and_override_resolve_exact_styles(self):
        self.write_map('{"loader-color":{"color":"#123456"}}')
        override = self.write_map('{"loader-color":{"color":"#abcdef"}}', override=True)
        for target in TARGETS:
            with self.subTest(target=target, location="default"):
                self.compile(target, has=True, color="#123456")
            with self.subTest(target=target, location="override"):
                self.compile(target, has=True, color="#abcdef", override=override)

    def test_missing_explicit_override_does_not_use_default(self):
        self.write_map('{"loader-color":{"color":"#123456"}}')
        missing = self.work / "missing-override.json"
        self.assertFalse(missing.exists())
        self.compile("c", override=missing)
        for target in ("js", "e"):
            with self.subTest(target=target):
                self.compile(target, override=missing, error=r"cannot open file: .*missing-override\.json")

    def test_malformed_map_is_not_silently_empty(self):
        for overridden in (False, True):
            path = self.write_map('{"loader-color":', override=overridden)
            for target in TARGETS:
                with self.subTest(override=overridden, target=target):
                    self.compile(target, override=path if overridden else None, error=r"\[JsonParsingError\]")

    def test_valid_override_does_not_read_malformed_default(self):
        self.write_map('{"loader-color":')
        override = self.write_map('{"loader-color":{"color":"#abcdef"}}', override=True)
        for target in TARGETS:
            with self.subTest(target=target):
                self.compile(target, has=True, color="#abcdef", override=override)

    def test_default_directory_is_not_a_map(self):
        self.map_path.mkdir(parents=True)
        for target in ("js", "e"):
            with self.subTest(target=target):
                self.compile(target, error=r"cannot open file: .*tailwind-styles\.json")
        # Native has always ignored non-file inputs, unlike JS/NimScript.
        self.compile("c")


if os.name == "posix":
    class TailwindLoaderPosixTests(TailwindLoaderBase):
        def test_unreadable_regular_map_in_unlistable_parent_still_fails(self):
            self.write_map('{"loader-color":{"color":"#123456"}}')
            self.map_path.chmod(0)
            self.map_path.parent.chmod(0o111)
            try:
                with self.assertRaises(PermissionError):
                    list(self.map_path.parent.iterdir())
                with self.assertRaises(PermissionError):
                    self.map_path.read_bytes()
                self.assertTrue(self.map_path.is_file())
                for target in TARGETS:
                    self.compile(target, error=r"cannot open file: .*tailwind-styles\.json")
            finally:
                self.map_path.parent.chmod(0o700)
                self.map_path.chmod(0o600)

        def test_denied_target_link_in_unlistable_parent_still_fails(self):
            target_dir = self.work / "denied target 'quote' $dollar `tick` ; λ"
            target_dir.mkdir()
            target = target_dir / "map.json"
            target.write_text('{"loader-color":{"color":"#123456"}}', encoding="utf-8")
            self.map_path.parent.mkdir()
            self.map_path.symlink_to(target)
            self.map_path.parent.chmod(0o111)
            target_dir.chmod(0)
            try:
                self.assertTrue(self.map_path.is_symlink())
                with self.assertRaises(PermissionError):
                    list(self.map_path.parent.iterdir())
                with self.assertRaises(PermissionError):
                    self.map_path.read_bytes()
                self.compile("c")
                for target_name in ("js", "e"):
                    self.compile(target_name, error=r"cannot open file: .*tailwind-styles\.json")
            finally:
                self.map_path.parent.chmod(0o700)
                target_dir.chmod(0o700)

        def test_link_query_failure_is_not_absence(self):
            with self.loader_fault(replacement=(
                    'gorgeEx("[ -L "', 'gorgeEx("deliberately_missing_link_query -L "')):
                for target in ("js", "e"):
                    self.compile(target, error="Tailwind link query failed")

        def test_helper_ignores_user_configuration(self):
            config = self.work / "user-config/nim"
            config.mkdir(parents=True)
            (config / "nim.cfg").write_text('--tailwindUserConfigMustNotExecute\n', encoding="utf-8")
            (config / "config.nims").write_text('{.error: "user config must not run".}\n', encoding="utf-8")
            environment = {"XDG_CONFIG_HOME": str(config.parent)}
            for target in ("js", "e"):
                self.compile(target, environment=environment)
            with self.loader_fault(replacement=('"--skipUserCfg:on",', '')):
                for target in ("js", "e"):
                    self.compile(target, environment=environment,
                                 error=r"(?is)Tailwind metadata query failed:.*tailwindUserConfigMustNotExecute")

        def test_read_only_sources_and_quoted_actual_compiler(self):
            compiler_root = self.work / 'compiler "double" and \'single\' $dollar `tick` ; λ'
            (compiler_root / "bin").mkdir(parents=True)
            compiler = compiler_root / "bin/nim"
            shutil.copyfile(self.selected_executable, compiler)
            compiler.chmod(0o555)
            self.assertEqual(hashlib.sha256(compiler.read_bytes()).digest(),
                             hashlib.sha256(self.selected_executable.read_bytes()).digest())
            (compiler_root / "lib").symlink_to(self.selected_library, target_is_directory=True)
            config = self.selected_library.parent / "config"
            self.assertTrue(config.is_dir(), "actual compiler installation config must be available")
            (compiler_root / "config").symlink_to(config, target_is_directory=True)
            files = [path for path in self.export.rglob("*") if path.is_file()]
            directories = [self.export] + [path for path in self.export.rglob("*") if path.is_dir()]
            before = {str(path.relative_to(self.export)): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in files}
            for path in files:
                path.chmod(0o444)
            for path in directories:
                path.chmod(0o555)
            try:
                with self.assertRaises(PermissionError):
                    (self.export / "unexpected-write").write_text("no", encoding="utf-8")
                for target in ("js", "e"):
                    self.compile(target, compiler=compiler, environment={"PATH": "/nonexistent"},
                                 extra_args=["--lib:" + str(self.selected_library)])
                after = {str(path.relative_to(self.export)): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in self.export.rglob("*") if path.is_file()}
                self.assertEqual(after, before)
            finally:
                for path in directories:
                    path.chmod(0o755)
                for path in files:
                    path.chmod(0o644)

        def test_unreadable_map_still_fails(self):
            for overridden in (False, True):
                path = self.write_map('{"loader-color":{"color":"#123456"}}', override=overridden)
                path.chmod(0)
                try:
                    with self.assertRaises(PermissionError, msg="fixture must actually deny reads"):
                        path.read_bytes()
                    for target in TARGETS:
                        with self.subTest(override=overridden, target=target):
                            self.compile(target, override=path if overridden else None, error=r"cannot open file:")
                finally:
                    path.chmod(0o600)

        def test_inaccessible_default_parent_still_fails(self):
            self.write_map('{"loader-color":{"color":"#123456"}}')
            self.map_path.parent.chmod(0)
            try:
                with self.assertRaises(PermissionError, msg="fixture must deny parent traversal"):
                    self.map_path.read_bytes()
                for target in ("js", "e"):
                    with self.subTest(target=target):
                        self.compile(target, error=r"cannot open file: .*tailwind-styles\.json")
            finally:
                self.map_path.parent.chmod(0o700)

        def test_readable_map_does_not_require_parent_listing(self):
            contents = '{"loader-color":{"color":"#123456"}}'
            self.write_map(contents)
            self.map_path.parent.chmod(0o111)
            try:
                with self.assertRaises(PermissionError, msg="fixture must deny directory listing"):
                    list(self.map_path.parent.iterdir())
                self.assertEqual(self.map_path.read_text(encoding="utf-8"), contents)
                for target in TARGETS:
                    with self.subTest(target=target):
                        self.compile(target, has=True, color="#123456")
            finally:
                self.map_path.parent.chmod(0o700)

        def test_unlistable_dangling_link_keeps_read_failure(self):
            self.map_path.parent.mkdir()
            self.map_path.symlink_to(self.work / "absent-target")
            self.map_path.parent.chmod(0o111)
            try:
                with self.assertRaises(PermissionError, msg="fixture must deny directory listing"):
                    list(self.map_path.parent.iterdir())
                self.assertTrue(self.map_path.is_symlink())
                self.assertFalse(self.map_path.exists())
                with self.assertRaises(FileNotFoundError):
                    self.map_path.read_bytes()
                for target in TARGETS:
                    with self.subTest(target=target, location="default"):
                        self.compile(target,
                                     error=None if target == "c" else r"cannot open file: .*tailwind-styles\.json")
                    with self.subTest(target=target, location="override"):
                        self.compile(target, override=self.map_path,
                                     error=None if target == "c" else r"cannot open file: .*tailwind-styles\.json")
            finally:
                self.map_path.parent.chmod(0o700)

        def test_observable_dangling_default_entries_still_fail(self):
            for kind in ("dangling-map", "dangling-build"):
                if self.map_path.parent.exists():
                    shutil.rmtree(self.map_path.parent)
                if kind == "dangling-build":
                    self.map_path.parent.symlink_to(self.work / "missing-build", target_is_directory=True)
                else:
                    self.map_path.parent.mkdir()
                    self.map_path.symlink_to(self.work / "missing-map")
                for target in ("js", "e"):
                    with self.subTest(kind=kind, target=target):
                        self.compile(target, error=r"cannot open file: .*tailwind-styles\.json")
                # Native has always ignored non-file inputs, unlike JS/NimScript.
                self.compile("c")


if __name__ == "__main__":
    print("Tailwind loader scopes: common" +
          (", POSIX permissions/symlinks" if os.name == "posix" else "") +
          " (host os.name=" + os.name + ")", flush=True)
    unittest.main(verbosity=2)
