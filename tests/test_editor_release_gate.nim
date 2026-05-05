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
    "layout_auto_grid_constraints_responsive",
    "component_dom_editing",
    "foundation_editors",
    "component_variant_editors",
    "style_class_cascade_token_manager",
    "inline_canvas_direct_manipulation",
    "svg_editors",
    "source_sync",
    "agent_edits",
    "browser_history",
    "pan_zoom",
    "search",
    "panels",
    "design_schema",
    "visual_review_gates",
    "package_imports"
  ]
  RequiredMatureCoreFeatureIds = [
    "edit_commands",
    "css_editors",
    "layout_auto_grid_constraints_responsive",
    "component_dom_editing",
    "inline_canvas_direct_manipulation",
    "source_sync",
    "agent_edits",
    "panels",
    "design_schema",
    "style_class_cascade_token_manager"
  ]
  RequiredCommands = [
    "direnv exec /home/zahary/metacraft/isonim nim c -r tests/test_editor_release_gate.nim",
    "direnv exec /home/zahary/metacraft/isonim just test-editor",
    "direnv exec /home/zahary/metacraft/isonim just editor-build",
    "direnv exec /home/zahary/metacraft/isonim just test-browser-editor-example",
    "direnv exec /home/zahary/metacraft/isonim just test-browser-editor-consumer",
    "direnv exec /home/zahary/metacraft/isonim just test-editor-visual-gates",
    "direnv exec /home/zahary/metacraft/metacraft-web just build-back-office-editor",
    "direnv exec /home/zahary/metacraft/metacraft-web nim c -r apps/back-office/tests/test_backoffice_editor_workspace.nim",
    "direnv exec /home/zahary/metacraft/metacraft-web nim c -r apps/back-office/tests/test_backoffice_editor_bridge_client.nim",
    "direnv exec /home/zahary/metacraft/metacraft-web just run-back-office-editor-test-matrix",
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
  M49HeadlessProperties = [
    "letter-spacing",
    "text-transform",
    "background-image",
    "background-size",
    "outline-offset",
    "border-style",
    "box-shadow",
    "filter",
    "backdrop-filter",
    "transform",
    "transition-duration",
    "flex-wrap",
    "grid-auto-flow",
    "overflow-x",
    "overscroll-behavior",
    "aspect-ratio",
    "sm:gap"
  ]
  M49BrowserVisualProperties = [
    "letter-spacing",
    "text-transform",
    "background-image",
    "background-size",
    "border-style",
    "filter",
    "transform",
    "transition-duration",
    "flex-wrap",
    "aspect-ratio"
  ]
  M49MetacraftCoveredProperties = [
    "letter-spacing",
    "background-size",
    "filter",
    "transform",
    "transition-duration",
    "aspect-ratio"
  ]

proc stringItems(node: JsonNode): seq[string] =
  for item in node.getElems:
    result.add item.getStr

proc propertiesCovered(properties: seq[string]; coverage: openArray[string]): bool =
  for property in properties:
    if property notin coverage:
      return false
  true

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
  if screenshots.hasKey("snapshotFiles"):
    for item in screenshots["snapshotFiles"].getElems:
      check fileExists(item.getStr)

proc checkImplementationReferences(row: JsonNode) =
  check row.hasKey("implementationReferences")
  check row["implementationReferences"].getElems.len > 0
  for item in row["implementationReferences"].getElems:
    check fileExists(item.getStr)

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
    check doc["maturityGate"].getStr == "M45 Mature Dogfood Release Gate"
    check not doc.hasKey("releaseGate")
    check doc["status"].getStr == "mature_dogfood_release_gate"
    check doc.hasKey("matureReleaseGate")
    check doc["matureReleaseGate"]["milestone"].getStr == "M45"
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
      checkImplementationReferences(row)

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
    check statusCounts.getOrDefault("prototype") == 0
    check statusCounts.getOrDefault("not_started") == 0
    check statusCounts.getOrDefault("figma_grade") == 0
    check statusCounts.getOrDefault("validated_in_metacraft") > 0

  test "mature_editor_release_gate_requires_figma_grade_core_features":
    let doc = matrix()
    let promoted = stringItems(doc["matureReleaseGate"][
      "promotedCoreFeatures"])
    var byId: Table[string, JsonNode]

    for row in doc["features"].getElems:
      byId[rowId(row)] = row
      check row["status"].getStr in [
        "functional",
        "figma_grade",
        "validated_in_metacraft"
      ]
      check not row["mockOnly"].getBool
      check not row["placeholderUi"].getBool
      check row["knownLimitations"].getStr.len > 40
      checkImplementationReferences(row)

    for featureId in RequiredMatureCoreFeatureIds:
      check featureId in promoted
      check byId.hasKey(featureId)
      if byId.hasKey(featureId):
        let row = byId[featureId]
        check row["status"].getStr == "validated_in_metacraft"
        check row["screenshotVisualAssertions"]["status"].getStr == "passing"
        check row["screenshotVisualAssertions"]["assertions"].getElems.len >= 2
        check row["screenshotVisualAssertions"].hasKey("evidence")
        check row["screenshotVisualAssertions"]["evidence"].getElems.len >= 2
        check row["consumerCoverage"]["isonimExample"]["status"].getStr ==
          "covered"
        check row["consumerCoverage"]["metacraftWeb"]["status"].getStr ==
          "covered"
        checkNamedTestsExist(row, "headlessTests")
        if row["playwrightRequired"].getBool or hasBrowserBehavior(row):
          checkNamedTestsExist(row, "playwrightTests")
        for item in row["screenshotVisualAssertions"]["evidence"].getElems:
          checkEvidenceReference(item.getStr)

  test "m48_write_bridge_hardening_evidence_is_versioned_and_bounded":
    let doc = matrix()
    let protocol = readFile("docs/editor-write-bridge-protocol.md")
    check protocol.contains("isonim.write-bridge.v1")
    check protocol.contains("symlink-owned files")
    check protocol.contains("remote multi-user collaboration")

    var sourceSync: JsonNode
    for row in doc["features"].getElems:
      if row["id"].getStr == "source_sync":
        sourceSync = row
        break
    check not sourceSync.isNil
    check sourceSync["implementation"].getStr.contains("M48 versioned")
    check sourceSync["knownLimitations"].getStr.contains(
      "Remote multi-user collaboration")
    check stringItems(sourceSync["implementationReferences"]).contains(
      "docs/editor-write-bridge-protocol.md")

  test "m49_long_tail_property_matrix_is_honest_and_evidenced":
    let doc = matrix()
    let guide = checkedText("docs/editor-long-tail-property-evidence.md")
    check doc.hasKey("longTailPropertyEvidence")
    check guide.contains("M49 Long-Tail CSS and Property Evidence")

    let validStatuses = [
      "validated",
      "read_only",
      "browser_limited",
      "consumer_unvalidated",
      "unsupported"
    ]
    let requiredFamilies = [
      "typography",
      "color_and_background",
      "border_shadow_and_effects",
      "filters",
      "transforms_and_transitions",
      "grid_and_flex",
      "overflow_position_and_sizing",
      "responsive_variants",
      "pseudo_state_variants",
      "container_queries"
    ]
    for family in requiredFamilies:
      check guide.contains(family)

    for row in doc["longTailPropertyEvidence"].getElems:
      let status = row["status"].getStr
      let properties = stringItems(row["representativeProperties"])
      check status in validStatuses
      check row["family"].getStr in requiredFamilies
      check properties.len > 0
      check row["limitations"].getStr.len > 30
      check row["implementationReferences"].getElems.len > 0
      for item in row["implementationReferences"].getElems:
        check fileExists(item.getStr)

      if row["headlessValidation"].getBool:
        check properties.propertiesCovered(M49HeadlessProperties)
      if row["browserBehavior"].getBool:
        check properties.propertiesCovered(M49BrowserVisualProperties)
      if row["visualEvidence"].getBool:
        check properties.propertiesCovered(M49BrowserVisualProperties)
      if row["metacraftEvidence"].getStr == "covered":
        check properties.propertiesCovered(M49MetacraftCoveredProperties)

      if status == "validated":
        check row["headlessValidation"].getBool
        check row["browserBehavior"].getBool
        check row["visualEvidence"].getBool
        check row["sourceWrite"].getStr in ["writable", "token_or_schema"]
        check row["metacraftEvidence"].getStr == "covered"
        check properties.propertiesCovered(M49MetacraftCoveredProperties)
      else:
        check row["metacraftEvidence"].getStr != "covered" or
          row["sourceWrite"].getStr != "none"
      if row["family"].getStr == "pseudo_state_variants":
        check status in ["browser_limited", "read_only"]
        check row["sourceWrite"].getStr == "none"
        check not row["headlessValidation"].getBool
        check not row["browserBehavior"].getBool
        check not row["visualEvidence"].getBool
        check row["metacraftEvidence"].getStr == "not_covered"

    checkNamedTestsExist(%*{
      "headlessTests": [{
        "name": "long_tail_property_schema_and_source_plans",
        "file": "tests/test_editor_viewmodels.nim"
      }]
    }, "headlessTests")
    checkNamedTestsExist(%*{
      "playwrightTests": [{
        "name": "e2e_long_tail_css_property_visual_evidence",
        "file": "tests/browser/specs/editor-example.spec.ts"
      }, {
        "name": "metacraft_long_tail_properties_validate_real_components",
        "file": "tests/browser/specs/metacraft-web-editor.spec.ts"
      }]
    }, "playwrightTests")

  test "mature_editor_full_matrix_passes_in_example_and_metacraft":
    let doc = matrix()
    let commands = stringItems(doc["maturityGateCommands"])
    for command in RequiredCommands:
      check command in commands

    let metacraftJust = checkedText("../metacraft-web/Justfile")
    check metacraftJust.contains("run-back-office-editor ")
    check metacraftJust.contains("run-back-office-editor-dev ")
    check metacraftJust.contains("run-back-office-editor-bridge-prod ")
    check metacraftJust.contains("run-back-office-editor-test-matrix:")

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

  test "mature_editor_docs_are_actionable_for_new_consumers":
    let guide = checkedText("docs/editor-dogfood-release.md")
    let readme = checkedText("README.md")
    let metacraftJust = checkedText("../metacraft-web/Justfile")

    for required in [
      "Add a design-system schema",
      "Add a token category",
      "Add a component variant",
      "Add a property editor",
      "Add a direct manipulation command",
      "Add an AI proposal scope",
      "run-back-office-editor-dev",
      "run-back-office-editor-test-matrix"
    ]:
      check guide.contains(required)

    check readme.contains("IsoNim Editor")
    check readme.contains("docs/editor-dogfood-release.md")
    check metacraftJust.contains("run-back-office-editor-test-matrix:")

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
