import std/[json, os, strutils, tables, unittest]

const
  MatrixPath = "docs/editor-feature-matrix.json"
  MaturityStatuses = [
    "not_started",
    "prototype",
    "functional",
    "figma_grade",
    "validated_in_metacraft"
  ]
  RequiredFeatureIds = [
    "edit_commands",
    "css_editors",
    "component_dom_editing",
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
    "direnv exec /home/zahary/metacraft/isonim nim c -r tests/test_editor_release_gate.nim",
    "direnv exec /home/zahary/metacraft/isonim just test-editor",
    "direnv exec /home/zahary/metacraft/isonim just editor-build",
    "direnv exec /home/zahary/metacraft/isonim just test-browser-editor-example",
    "direnv exec /home/zahary/metacraft/isonim just test-browser-editor-consumer",
    "direnv exec /home/zahary/metacraft/metacraft-web just build-back-office-editor",
    "direnv exec /home/zahary/metacraft/metacraft-web nim c -r apps/back-office/tests/test_backoffice_editor_workspace.nim",
    "direnv exec /home/zahary/metacraft/nim-agents just test"
  ]
  RequiredHeuristics = [
    "density",
    "discoverability",
    "keyboardOperation",
    "panelResizing",
    "selectionLatency",
    "layoutJumping"
  ]
  BrowserBehaviorsRequiringPlaywright = [
    "pointer",
    "focus",
    "iframe",
    "canvas"
  ]
  ConsumerCoverageStatuses = [
    "covered",
    "covered_headless",
    "covered_indirectly",
    "workspace_api_compatible"
  ]
  WeakTestMarkers = [
    "." & "sk" & "ip(",
    "." & "on" & "ly(",
    "test" & ".sk" & "ip",
    "test" & ".on" & "ly",
    "suite" & ".sk" & "ip",
    "suite" & ".on" & "ly",
    "describe" & ".sk" & "ip",
    "describe" & ".on" & "ly",
    "it" & ".sk" & "ip(",
    "it" & ".on" & "ly(",
    "xit" & "(",
    "test" & ".to" & "do",
    "to" & "do(",
    "pending" & "(",
    "{." & "skip.",
    "{." & "disabled.",
    "{." & "ignore."
  ]
  PlaceholderAssertions = [
    "check" & " true",
    "doAssert" & " true",
    "assert" & " true",
    "expect(true)" & ".toBe(true)",
    "expect(true)" & ".toEqual(true)"
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
  if path.endsWith(".ts") or path.endsWith(".mjs"):
    return text.contains("test(\"" & name & "\"") or
      text.contains("test('" & name & "'")
  false

proc isKnownTestPath(path: string): bool =
  path.startsWith("tests/") or
    path.startsWith("../metacraft-web/apps/back-office/tests/")

proc checkNamedTestsExist(row: JsonNode; key: string) =
  if not row.hasKey(key):
    return
  for entry in row[key].getElems:
    let file = testFile(entry)
    let name = testName(entry)
    check isKnownTestPath(file)
    check file.endsWith(".nim") or file.endsWith(".ts") or
      file.endsWith(".mjs")
    let text = checkedText(file)
    check hasTestDeclaration(file, text, name)

proc sourceFiles(root: string): seq[string] =
  for path in walkDirRec(root):
    if path.contains("node_modules") or path.endsWith("package-lock.json"):
      continue
    if path.endsWith(".nim") or path.endsWith(".ts") or
        path.endsWith(".md") or path.endsWith(".json"):
      result.add path

proc evidenceFile(evidence: string): string =
  let separator = evidence.find(":")
  if separator >= 0:
    evidence[0 ..< separator]
  else:
    evidence

proc evidenceDetail(evidence: string): string =
  let separator = evidence.find(":")
  if separator >= 0:
    evidence[separator + 1 .. ^1]
  else:
    ""

proc checkEvidenceReference(evidence: string) =
  let file = evidenceFile(evidence)
  check file.len > 0
  check fileExists(file)

  let detail = evidenceDetail(evidence)
  if detail.len > 0 and (file.endsWith(".nim") or file.endsWith(".ts") or
      file.endsWith(".mjs")):
    let text = checkedText(file)
    check hasTestDeclaration(file, text, detail)

proc hasBrowserBehavior(row: JsonNode): bool =
  if not row.hasKey("browserBehavior"):
    return false
  for behavior in row["browserBehavior"].getElems:
    if behavior.getStr in BrowserBehaviorsRequiringPlaywright:
      return true
  false

proc checkConsumerCoverage(row: JsonNode) =
  check row.hasKey("consumerCoverage")
  for consumer in ["isonimExample", "metacraftWeb"]:
    check row["consumerCoverage"].hasKey(consumer)
    let coverage = row["consumerCoverage"][consumer]
    check coverage["status"].getStr in ConsumerCoverageStatuses
    check coverage.hasKey("evidence")
    check coverage["evidence"].getElems.len > 0
    for item in coverage["evidence"].getElems:
      checkEvidenceReference(item.getStr)

proc checkScreenshotRecord(row: JsonNode) =
  check row.hasKey("screenshotVisualAssertions")
  let screenshots = row["screenshotVisualAssertions"]
  check screenshots.hasKey("requiredForFigmaGrade")
  check screenshots.hasKey("status")
  check screenshots.hasKey("assertions")
  check screenshots.hasKey("notes")
  check screenshots["notes"].getStr.len > 20

proc checkFigmaGradeRequirements(row: JsonNode) =
  let status = row["status"].getStr
  if status notin ["figma_grade", "validated_in_metacraft"]:
    return
  check row["headlessTests"].getElems.len > 0
  checkNamedTestsExist(row, "headlessTests")
  check not row["mockOnly"].getBool
  check not row["placeholderUi"].getBool
  check row["screenshotVisualAssertions"]["status"].getStr == "passing"
  check row["screenshotVisualAssertions"]["assertions"].getElems.len > 0
  check row["screenshotVisualAssertions"].hasKey("evidence")
  if row["screenshotVisualAssertions"].hasKey("evidence"):
    check row["screenshotVisualAssertions"]["evidence"].getElems.len > 0
    for item in row["screenshotVisualAssertions"]["evidence"].getElems:
      checkEvidenceReference(item.getStr)
  check row["consumerCoverage"]["isonimExample"]["status"].getStr == "covered"
  if status == "validated_in_metacraft":
    check row["consumerCoverage"]["metacraftWeb"]["status"].getStr == "covered"
  if hasBrowserBehavior(row):
    check row["playwrightTests"].getElems.len > 0
    checkNamedTestsExist(row, "playwrightTests")

proc checkNoWeakMarkers(path: string) =
  let text = readFile(path)
  for marker in WeakTestMarkers:
    check not text.contains(marker)
  for marker in PlaceholderAssertions:
    check not text.contains(marker)

suite "IsoNim editor maturity gate":

  test "editor_quality_matrix_blocks_overclaimed_features":
    let doc = matrix()
    check doc["maturityGate"].getStr == "M32 Editor Maturity Gate"
    check not doc.hasKey("releaseGate")
    check doc["status"].getStr == "functional_rebaseline"
    check doc["policy"]["headlessFirst"].getBool
    check doc["policy"]["playwrightRequiredForBrowserBehavior"].getBool
    check doc["policy"]["functionalRowsRequireAutomatedTests"].getBool
    check not doc["policy"]["mockOnlyFigmaGradeAllowed"].getBool
    check not doc["policy"]["placeholderFigmaGradeAllowed"].getBool
    check not doc["policy"]["weakTestsAllowedForFigmaGrade"].getBool
    check doc["policy"]["figmaGradeRequiresVisualAssertions"].getBool

    for status in MaturityStatuses:
      check status in stringItems(doc["statusValues"])
    check doc["statusValues"].getElems.len == MaturityStatuses.len
    for status in stringItems(doc["statusValues"]):
      check status in MaturityStatuses

    for heuristic in RequiredHeuristics:
      check doc["acceptanceHeuristics"].hasKey(heuristic)
      check doc["acceptanceHeuristics"][heuristic]["criteria"].getElems.len > 0

    var byId: Table[string, JsonNode]
    for row in doc["features"].getElems:
      byId[rowId(row)] = row

    for featureId in RequiredFeatureIds:
      check byId.hasKey(featureId)

    for row in doc["features"].getElems:
      check row["status"].getStr in MaturityStatuses
      check row["status"].getStr != "completed"
      check row["targetWorkflow"].getStr.len > 40
      check row["implementation"].getStr.len > 24
      check row.hasKey("knownLimitations")
      check row.hasKey("mockOnly")
      check row.hasKey("placeholderUi")
      check row.hasKey("browserBehavior")
      check row.hasKey("headlessTests")
      check row.hasKey("playwrightTests")
      check row.hasKey("playwrightRequired")

      if row["status"].getStr in ["functional", "figma_grade", "validated_in_metacraft"]:
        check not row["mockOnly"].getBool
        check row["headlessTests"].getElems.len > 0
        checkNamedTestsExist(row, "headlessTests")

      if row["playwrightRequired"].getBool or hasBrowserBehavior(row):
        check row["playwrightTests"].getElems.len > 0
        checkNamedTestsExist(row, "playwrightTests")
      else:
        check row.hasKey("playwrightReason")
        check row["playwrightReason"].getStr.len > 24

      checkScreenshotRecord(row)
      checkConsumerCoverage(row)
      checkFigmaGradeRequirements(row)

  test "editor_quality_matrix_distinguishes_functional_from_figma_grade":
    let doc = matrix()
    var statusCounts = initTable[string, int]()

    for row in doc["features"].getElems:
      let status = row["status"].getStr
      statusCounts[status] = statusCounts.getOrDefault(status) + 1

      if row["placeholderUi"].getBool or
          row["screenshotVisualAssertions"]["assertions"].getElems.len == 0:
        check status notin ["figma_grade", "validated_in_metacraft"]

      if status == "functional":
        check row["headlessTests"].getElems.len > 0
        check row["implementation"].getStr.len > 24
        check row["knownLimitations"].getStr.len > 24

    check statusCounts.getOrDefault("functional") > 0
    check statusCounts.getOrDefault("prototype") > 0
    check statusCounts.getOrDefault("figma_grade") == 0
    check statusCounts.getOrDefault("validated_in_metacraft") == 0

  test "no_weak_editor_quality_tests":
    let doc = matrix()
    var scanned: Table[string, bool]

    for row in doc["features"].getElems:
      for key in ["headlessTests", "playwrightTests"]:
        for entry in row[key].getElems:
          scanned[testFile(entry)] = true

    for path in scanned.keys:
      checkNoWeakMarkers(path)

    checkNoWeakMarkers("tests/test_editor_release_gate.nim")

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
    let commands = stringItems(doc["maturityGateCommands"])
    for command in RequiredCommands:
      check command in commands
    check "isonim/editor" in stringItems(doc["policy"]["publicConsumerImports"])
    check "isonim/editor/browser" in stringItems(doc["policy"]["publicConsumerImports"])
