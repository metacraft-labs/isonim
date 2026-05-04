import std/[json, os, strutils, tables, unittest]

const
  MatrixPath = "docs/editor-feature-matrix.json"
  RequiredFeatureIds = [
    "edit_commands",
    "css_editors",
    "foundation_editors",
    "component_variant_editors",
    "svg_editors",
    "source_sync",
    "agent_edits",
    "browser_history",
    "pan_zoom",
    "search",
    "panels",
    "package_imports"
  ]
  RequiredCommands = [
    "direnv exec /home/zahary/metacraft/isonim just test-editor",
    "direnv exec /home/zahary/metacraft/isonim just editor-build",
    "direnv exec /home/zahary/metacraft/isonim just test-browser-editor-example",
    "direnv exec /home/zahary/metacraft/isonim just test-browser-editor-consumer",
    "direnv exec /home/zahary/metacraft/metacraft-web just build-back-office-editor",
    "direnv exec /home/zahary/metacraft/metacraft-web nim c -r apps/back-office/tests/test_backoffice_editor_workspace.nim",
    "direnv exec /home/zahary/metacraft/nim-agents just test"
  ]
  WeakTestMarkers = [
      "." & "skip(",
      "." & "only(",
      "test" & ".skip",
      "test" & ".only",
      "suite" & ".skip",
      "suite" & ".only",
      "xit" & "(",
      "it" & ".only(",
      "it" & ".skip("
  ]

proc stringItems(node: JsonNode): seq[string] =
  for item in node.getElems:
    result.add item.getStr

proc matrix(): JsonNode =
  parseFile(MatrixPath)

proc rowId(row: JsonNode): string =
  row["id"].getStr

proc testName(entry: JsonNode): string =
  entry["name"].getStr

proc testFile(entry: JsonNode): string =
  entry["file"].getStr

proc checkedText(path: string): string =
  check fileExists(path)
  if fileExists(path):
    readFile(path)
  else:
    ""

proc hasTestDeclaration(path, text, name: string): bool =
  if path.endsWith(".nim"):
    return text.contains("test \"" & name & "\":")
  if path.endsWith(".ts"):
    return text.contains("test(\"" & name & "\"") or
      text.contains("test('" & name & "'")
  false

proc checkNamedTestsExist(row: JsonNode; key: string) =
  if not row.hasKey(key):
    return
  for entry in row[key].getElems:
    let file = testFile(entry)
    let name = testName(entry)
    check file.startsWith("tests/")
    check file.endsWith(".nim") or file.endsWith(".ts")
    let text = checkedText(file)
    check hasTestDeclaration(file, text, name)

proc sourceFiles(root: string): seq[string] =
  for path in walkDirRec(root):
    if path.contains("node_modules") or path.endsWith("package-lock.json"):
      continue
    if path.endsWith(".nim") or path.endsWith(".ts") or
        path.endsWith(".md") or path.endsWith(".json"):
      result.add path

suite "IsoNim editor release gate":

  test "editor_feature_matrix_has_no_mock_or_missing_feature_rows":
    let doc = matrix()
    check doc["releaseGate"].getStr == "M31 Full Editor Dogfood Release Gate"
    check doc["status"].getStr == "completed"
    check doc["policy"]["headlessFirst"].getBool
    check doc["policy"]["playwrightOnlyForBrowserBehavior"].getBool
    check doc["policy"]["completedRowsRequireAutomatedTests"].getBool
    check not doc["policy"]["mockOnlyCompletedRowsAllowed"].getBool

    var byId: Table[string, JsonNode]
    for row in doc["features"].getElems:
      byId[rowId(row)] = row

    for featureId in RequiredFeatureIds:
      check byId.hasKey(featureId)

    for row in doc["features"].getElems:
      check row["status"].getStr == "completed"
      check not row["mockOnly"].getBool
      check row["implementation"].getStr.len > 24
      check not row["implementation"].getStr.toLowerAscii.contains("mock-up")
      check row.hasKey("headlessTests")
      check row["headlessTests"].getElems.len > 0

      checkNamedTestsExist(row, "headlessTests")
      if row["playwrightRequired"].getBool:
        check row.hasKey("playwrightTests")
        check row["playwrightTests"].getElems.len > 0
        checkNamedTestsExist(row, "playwrightTests")
      else:
        check row.hasKey("playwrightReason")
        check row["playwrightReason"].getStr.len > 24

  test "editor_full_headless_and_browser_matrix_passes":
    let doc = matrix()
    let commands = stringItems(doc["releaseGateCommands"])
    for command in RequiredCommands:
      check command in commands

    var browserCovered = initTable[string, bool]()
    for row in doc["features"].getElems:
      if row["playwrightRequired"].getBool:
        browserCovered[rowId(row)] = row["playwrightTests"].getElems.len > 0

    for featureId, covered in browserCovered:
      check covered

    let editorTestFiles = sourceFiles("tests")
    for path in editorTestFiles:
      if path.endsWith("tests/test_editor_release_gate.nim"):
        continue
      let text = readFile(path)
      for marker in WeakTestMarkers:
        check not text.contains(marker)

  test "editor_framework_consumer_boundary_is_preserved":
    let publicApi = checkedText("src/isonim/editor.nim")
    let browserApi = checkedText("src/isonim/editor/browser.nim")
    let browserImportTest = checkedText("tests/test_editor_public_browser_imports.nim")

    check publicApi.contains("export types")
    check publicApi.contains("export viewmodels")
    check publicApi.contains("export workspace")
    check not publicApi.contains("examples/")
    check not publicApi.contains("demos/")
    check not browserApi.contains("examples/")
    check not browserApi.contains("demos/")

    check browserImportTest.contains("import isonim/editor")
    check browserImportTest.contains("import isonim/editor/browser")
    check not browserImportTest.contains("isonim/editor/browser_vector_adapter")
    check not browserImportTest.contains("isonim/editor/views/")
    check not browserImportTest.contains("isonim/editor/viewmodels")
    check not browserImportTest.contains("isonim/editor/types")

    for path in sourceFiles("src/isonim/editor"):
      if path.endsWith("src/isonim/editor/main.nim"):
        continue
      let text = readFile(path).toLowerAscii
      check not text.contains("metacraft-web")
      check not text.contains("codetracer")

    let metacraftFiles = [
      "../metacraft-web/apps/back-office/src/backoffice_editor/workspace.nim",
      "../metacraft-web/apps/back-office/src/backoffice_editor/main.nim",
      "../metacraft-web/apps/back-office/tests/test_backoffice_editor_workspace.nim"
    ]
    for path in metacraftFiles:
      check fileExists(path)
      let text = checkedText(path)
      check not text.contains("isonim/editor/viewmodels")
      check not text.contains("isonim/editor/types")
      check not text.contains("isonim/editor/workspace")
      check not text.contains("isonim/editor/views/")
      check not text.contains("isonim/editor/browser_vector_adapter")

    let doc = matrix()
    check "isonim/editor" in stringItems(doc["policy"]["publicConsumerImports"])
    check "isonim/editor/browser" in stringItems(doc["policy"]["publicConsumerImports"])
