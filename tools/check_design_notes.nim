## tools/check_design_notes.nim
##
## Checks the doc comments of the modules a user of the reactive core learns
## first (the async value, stream and callback services, the ViewModel base,
## and the owner, error-routing and flush code of the core):
##
## 1. every exported symbol of each listed module has a doc comment, and so
##    has every exported field of its exported object types;
## 2. `nim doc` reports no warning and no markup error for a listed module,
##    on the C backend, on the JS backend and with the optional recording
##    defines;
## 3. no listed module names an internal document: a project-management
##    repository (a name ending in `-pm`), a Markdown file, an acceptance
##    requirement identifier (`ABC-AREQ1`), a milestone or gate identifier
##    (`ABC-M1`, `ABC-G1`) or a design-record entry identifier (`D` and a
##    number, as a whole word). When a project-management repository is
##    checked out next to this one, the names of its specification files
##    (hyphenated, and not the name of a checked-out repository) are refused
##    too, with or without `.md`.
##
## The symbols come from the compiler itself: each module is run through
## `nim jsondoc`, whose entries are the module's exported symbols with their
## rendered doc comments, so nothing here re-implements Nim's parser.
##
## Usage, from the repository root inside the dev shell:
##
##   nim r tools/check_design_notes.nim              # check the modules
##   nim r tools/check_design_notes.nim --self-test  # show it is not vacuous
##
## `--self-test` copies `src/` to a temporary directory, shows that the
## unmodified copy passes, then applies one mutation at a time (a doc comment
## deleted, a field's doc comment deleted, a broken doc comment, a Markdown
## file name, a requirement identifier, a milestone identifier, an entry
## identifier, a project-management repository name, a specification name)
## and requires the check to reject each with the expected finding. It also
## requires the module list to be non-empty and every module to export at
## least one symbol, which the plain run checks as well. Exit status: 0 when
## everything passes, 1 otherwise.

import std/[algorithm, json, os, osproc, sets, strutils, tempfiles]

const
  ListedModules* = [
    "src/isonim/services/async_value.nim",
    "src/isonim/services/streams.nim",
    "src/isonim/services/callbacks.nim",
    "src/isonim/viewmodel.nim",
    "src/isonim/core/owner.nim",
    "src/isonim/core/graph.nim",
    "src/isonim/core/computation.nim",
    "src/isonim/core/batch.nim",
    "src/isonim/dsl/components.nim",
  ]
    ## The modules checked, relative to the repository root.

  Passes = [
    "",
    "--backend:js",
    "-d:isonimInternalFlushObservation -d:isonimRecordable",
  ]
    ## The compiler configurations each module is documented in. Symbols
    ## under `when defined(...)` exist only in some of them; a symbol is
    ## checked in every configuration that has it.

type
  FindingKind* = enum
    fkUndocumented = "undocumented symbol"
    fkUndocumentedField = "undocumented field"
    fkNoModuleDoc = "no module documentation"
    fkNoSymbols = "no exported symbols"
    fkDocFailed = "nim jsondoc failed"
    fkDocWarning = "nim doc warning"
    fkDocError = "nim doc error"
    fkPrivateRepo = "names a project-management repository"
    fkMarkdownFile = "names a Markdown file"
    fkRequirementId = "names a requirement identifier"
    fkMilestoneId = "names a milestone identifier"
    fkEntryId = "names a design-record entry"
    fkSpecName = "names a specification"

  Finding* = object
    kind*: FindingKind
    module*: string ## Relative to the checked root.
    detail*: string

  ModuleReport* = object
    module*: string
    symbols*: int    ## Exported symbols found, over every configuration.
    fields*: int     ## Exported fields of exported object types.

  Report* = object
    findings*: seq[Finding]
    modules*: seq[ModuleReport]

proc isIdentChar(c: char): bool = c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}

proc charAt(s: string; i: int): char =
  ## `s[i]`, or a space outside the string, so boundary tests need no
  ## range checks.
  if i >= 0 and i < s.len: s[i] else: ' '

# ---------------------------------------------------------------------------
# Names that must not appear in a listed module
# ---------------------------------------------------------------------------

proc lineOf(text: string; pos: int): int =
  1 + text[0 ..< pos].count('\n')

proc scanText*(text: string; specNames: openArray[string]): seq[(FindingKind, string)] =
  ## Every internal name in `text`, with its line. Plain scanning rather than
  ## regular expressions, so the check needs no PCRE library at run time.
  for i in 0 ..< text.len:
    let c = text[i]
    # `<name>-pm` as a whole word: a project-management repository.
    if c == '-' and text.continuesWith("pm", i + 1) and
        (isIdentChar(text.charAt(i - 1))) and
        not (isIdentChar(text.charAt(i + 3)) or text.charAt(i + 3) == '-'):
      var s = i
      while s > 0 and (isIdentChar(text[s - 1]) or text[s - 1] == '-'): dec s
      result.add((fkPrivateRepo, "line " & $lineOf(text, i) & ": " & text[s .. i + 2]))
    # `<name>.md`: a Markdown document.
    if c == '.' and text.continuesWith("md", i + 1) and
        (isIdentChar(text.charAt(i - 1)) or text.charAt(i - 1) == '-') and
        not isIdentChar(text.charAt(i + 3)):
      var s = i
      while s > 0 and (isIdentChar(text[s - 1]) or text[s - 1] in {'-', '/'}): dec s
      result.add((fkMarkdownFile, "line " & $lineOf(text, i) & ": " & text[s .. i + 2]))
    # `<PREFIX>-AREQ<n>`, `<PREFIX>-M<n>`, `<PREFIX>-G<n>`.
    if c == '-' and text.charAt(i - 1) in {'A'..'Z'}:
      var s = i
      while s > 0 and text[s - 1] in {'A'..'Z'}: dec s
      let prefixLen = i - s
      if not isIdentChar(text.charAt(s - 1)):
        if text.continuesWith("AREQ", i + 1) and text.charAt(i + 5) in {'0'..'9'}:
          result.add((fkRequirementId, "line " & $lineOf(text, i) & ": " &
                      text[s .. i + 5]))
        elif prefixLen >= 2 and text.charAt(i + 1) in {'M', 'G'} and
            text.charAt(i + 2) in {'0'..'9'}:
          result.add((fkMilestoneId, "line " & $lineOf(text, i) & ": " &
                      text[s .. i + 2]))
    # `D<n>` as a whole word: an entry of the design record.
    if c == 'D' and not isIdentChar(text.charAt(i - 1)) and
        text.charAt(i + 1) in {'0'..'9'}:
      var e = i + 1
      while e < text.len and text[e] in {'0'..'9'}: inc e
      if not isIdentChar(text.charAt(e)):
        result.add((fkEntryId, "line " & $lineOf(text, i) & ": " & text[i ..< e]))
  for name in specNames:
    var at = text.find(name)
    while at >= 0:
      let before = text.charAt(at - 1)
      let after = text.charAt(at + name.len)
      if not (isIdentChar(before) or before == '-') and
          not (isIdentChar(after) or after == '-'):
        result.add((fkSpecName, "line " & $lineOf(text, at) & ": " & name))
      at = text.find(name, at + 1)

proc siblingSpecNames*(workspace: string): seq[string] =
  ## The names of the specification files of every project-management
  ## repository checked out in `workspace` (a directory ending in `-pm` with a
  ## `spec/` directory), keeping only hyphenated names that are not also the
  ## name of a checked-out repository (which public code may name). Empty
  ## when there is none, as in a clone of this repository on its own.
  var repos = initHashSet[string]()
  for kind, path in walkDir(workspace):
    if kind in {pcDir, pcLinkToDir}: repos.incl lastPathPart(path)
  var names = initHashSet[string]()
  for kind, path in walkDir(workspace):
    if kind notin {pcDir, pcLinkToDir} or not lastPathPart(path).endsWith("-pm"):
      continue
    let spec = path / "spec"
    if not dirExists(spec): continue
    for file in walkDirRec(spec):
      let (_, stem, ext) = splitFile(file)
      if ext == ".md" and '-' in stem and stem notin repos:
        names.incl stem
  for n in names: result.add n
  result.sort()

# ---------------------------------------------------------------------------
# Exported symbols, from the compiler's own documentation output
# ---------------------------------------------------------------------------

proc fieldFindings(code: string): (int, seq[string]) =
  ## The exported fields of a type's source (`code` of a jsondoc entry, which
  ## keeps the field comments), and those without a doc comment on the field's
  ## line or on the more indented lines right after it.
  let lines = code.splitLines()
  for i, line in lines:
    let t = line.strip()
    let star = t.find('*')
    if star <= 0 or not t[0 .. star - 1].validIdentifier: continue
    var rest = t[star + 1 .. ^1].strip()
    if rest.startsWith("{."):
      let close = rest.find(".}")
      if close < 0: continue
      rest = rest[close + 2 .. ^1].strip()
    if not rest.startsWith(":"): continue
    inc result[0]
    let name = t[0 .. star - 1]
    if "##" in t: continue
    let indent = line.len - line.strip(trailing = false).len
    var documented = false
    var j = i + 1
    while j < lines.len:
      let next = lines[j]
      let nt = next.strip()
      if nt.len == 0: (inc j; continue)
      let nindent = next.len - next.strip(trailing = false).len
      documented = nindent > indent and nt.startsWith("##")
      break
    if not documented: result[1].add name

proc checkModule(root, module, docDir: string; specNames: openArray[string];
                 report: var Report) =
  ## Adds the findings of one module (relative to `root`) to `report`.
  let path = root / module
  var mr = ModuleReport(module: module)
  let text = readFile(path)
  for (kind, detail) in scanText(text, specNames):
    report.findings.add Finding(kind: kind, module: module, detail: detail)
  var seen = initHashSet[string]()
  var hasModuleDoc = false
  let nimEverywhere = root / ".." / "nim-everywhere" / "src"
  for p, flags in Passes:
    let json = docDir / (splitFile(module).name & "_" & $p & ".json")
    var args = @["jsondoc", "--hints:off", "--warnings:on", "--listFullPaths:on",
                 "--index:off", "--path:" & (root / "src"),
                 "--path:" & nimEverywhere, "-o:" & json]
    for f in flags.splitWhitespace(): args.add f
    args.add path
    let (output, code) = execCmdEx(quoteShellCommand(@[getCurrentCompilerExe()] & args),
                                   workingDir = root)
    if code != 0:
      report.findings.add Finding(kind: fkDocFailed, module: module,
        detail: "[" & flags & "] exit " & $code & "\n" & output)
      continue
    for line in output.splitLines():
      # Markup errors in a doc comment are reported as `Error:` lines while
      # the compiler still exits 0, so both kinds of line are findings.
      if path in line:
        if "Warning:" in line:
          report.findings.add Finding(kind: fkDocWarning, module: module,
            detail: "[" & flags & "] " & line)
        elif "Error:" in line:
          report.findings.add Finding(kind: fkDocError, module: module,
            detail: "[" & flags & "] " & line)
    let doc = parseFile(json)
    if doc{"moduleDescription"}.getStr.strip.len > 0: hasModuleDoc = true
    for entry in doc{"entries"}.getElems:
      let name = entry{"name"}.getStr
      let key = entry{"type"}.getStr & " " & name & " (line " &
                $entry{"line"}.getInt & ")"
      if key notin seen:
        seen.incl key
        inc mr.symbols
        if entry{"type"}.getStr == "skType":
          let (count, missing) = fieldFindings(entry{"code"}.getStr)
          mr.fields += count
          for f in missing:
            report.findings.add Finding(kind: fkUndocumentedField, module: module,
              detail: name & "." & f)
      if entry{"description"}.getStr.strip.len == 0:
        let d = "[" & flags & "] " & key
        report.findings.add Finding(kind: fkUndocumented, module: module, detail: d)
  if not hasModuleDoc:
    report.findings.add Finding(kind: fkNoModuleDoc, module: module)
  if mr.symbols == 0:
    report.findings.add Finding(kind: fkNoSymbols, module: module)
  report.modules.add mr

proc dedupe(findings: seq[Finding]): seq[Finding] =
  ## A symbol undocumented in several configurations is reported once.
  var seen = initHashSet[string]()
  for f in findings:
    let key = $f.kind & "|" & f.module & "|" &
      (if f.kind == fkUndocumented: f.detail.split("] ", 1)[^1] else: f.detail)
    if key notin seen:
      seen.incl key
      result.add f

proc check*(root: string; modules: openArray[string];
            specNames: openArray[string]): Report =
  ## Checks `modules` (relative to `root`, the repository root or a copy of
  ## it). An empty module list is itself a finding, so the check never
  ## passes by checking nothing.
  if modules.len == 0:
    result.findings.add Finding(kind: fkNoSymbols, module: "(none)",
                                detail: "the module list is empty")
    return
  let docDir = createTempDir("check_design_notes_doc", "")
  try:
    for m in modules: checkModule(root, m, docDir, specNames, result)
  finally:
    removeDir(docDir)
  result.findings = dedupe(result.findings)

proc printReport(r: Report) =
  for m in r.modules:
    echo "  ", m.module, ": ", m.symbols, " exported symbols, ", m.fields,
      " exported fields"
  for f in r.findings:
    echo "  FAIL ", f.module, ": ", $f.kind, (if f.detail.len > 0: ": " & f.detail else: "")

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

type Mutation = object
  name: string
  module: string
  find: string     ## Replaced by `replace`; empty: `replace` is appended.
  replace: string
  expect: set[FindingKind]
  expectDetail: string

proc selfTest(repo: string; specNames: seq[string]): bool =
  ## Runs the check on a copy of `src/` and on one mutation of it at a time.
  result = true
  let tmp = createTempDir("check_design_notes_self", "")
  try:
    # The copy sits beside a link to the sibling the modules import, at the
    # same relative place, so the copy compiles as the original does.
    let root = tmp / "isonim"
    createDir(root)
    copyDir(repo / "src", root / "src")
    createSymlink(repo / ".." / "nim-everywhere", tmp / "nim-everywhere")

    let clean = check(root, ListedModules, specNames)
    if clean.findings.len == 0 and clean.modules.len == ListedModules.len:
      echo "  ok   the unmodified copy passes"
    else:
      echo "  FAIL the unmodified copy does not pass:"
      printReport(clean)
      result = false
    for m in clean.modules:
      if m.symbols == 0:
        echo "  FAIL ", m.module, " exports no symbol"
        result = false
    let empty = check(root, newSeq[string](), specNames)
    if empty.findings.len > 0:
      echo "  ok   an empty module list is rejected"
    else:
      echo "  FAIL an empty module list passes"
      result = false

    var mutations = @[
      Mutation(name: "a proc's doc comment deleted", module: "src/isonim/core/owner.nim",
        find: "  ## Returns the current owner.\n", replace: "",
        expect: {fkUndocumented}, expectDetail: "getOwner"),
      Mutation(name: "a field's doc comment deleted", module: "src/isonim/core/graph.nim",
        find: "      ## The computations that read this signal in their last run.\n",
        replace: "", expect: {fkUndocumentedField}, expectDetail: "observers"),
      Mutation(name: "a doc comment with broken markup",
        module: "src/isonim/core/owner.nim",
        find: "  ## Returns the current owner.\n",
        replace: "  ## Returns the current owner.\n  ##\n  ## .. unknownDirective:: x\n",
        expect: {fkDocError, fkDocFailed}, expectDetail: "unknowndirective"),
      Mutation(name: "a compiler warning in a module", module: "src/isonim/core/owner.nim",
        replace: "\n{.warning: \"check_design_notes probe\".}\n",
        expect: {fkDocWarning}, expectDetail: "check_design_notes probe"),
      Mutation(name: "a Markdown file named", module: "src/isonim/services/async_value.nim",
        replace: "\n# See some-design-notes.md for why.\n",
        expect: {fkMarkdownFile}, expectDetail: "some-design-notes.md"),
      Mutation(name: "a requirement identifier", module: "src/isonim/viewmodel.nim",
        replace: "\n# Serves XYZ-AREQ7.\n", expect: {fkRequirementId},
        expectDetail: "XYZ-AREQ7"),
      Mutation(name: "a milestone identifier", module: "src/isonim/core/batch.nim",
        replace: "\n# Landed by XYZ-M4.\n", expect: {fkMilestoneId},
        expectDetail: "XYZ-M4"),
      Mutation(name: "a design-record entry", module: "src/isonim/core/computation.nim",
        replace: "\n# As decided in D90.\n", expect: {fkEntryId}, expectDetail: "D90"),
      Mutation(name: "a project-management repository",
        module: "src/isonim/dsl/components.nim",
        replace: "\n# Planned in acme-pm.\n", expect: {fkPrivateRepo},
        expectDetail: "acme-pm"),
    ]
    if specNames.len > 0:
      # A real specification name, without its extension, so only the
      # specification-name rule can catch it.
      mutations.add Mutation(name: "a specification named without .md",
        module: "src/isonim/services/streams.nim",
        replace: "\n# See " & specNames[0] & ".\n", expect: {fkSpecName},
        expectDetail: specNames[0])
    else:
      echo "  note no project-management checkout beside this repository: the ",
        "specification-name rule is not exercised"
    for m in mutations:
      let path = root / m.module
      let original = readFile(path)
      var mutated: string
      if m.find.len == 0:
        mutated = original & m.replace
      elif original.count(m.find) == 1:
        mutated = original.replace(m.find, m.replace)
      else:
        echo "  FAIL ", m.name, ": the text to mutate is not in ", m.module, " once"
        result = false
        continue
      writeFile(path, mutated)
      try:
        let r = check(root, [m.module], specNames)
        var caught = false
        for f in r.findings:
          if f.kind in m.expect and m.expectDetail in f.detail: caught = true
        if caught:
          echo "  ok   rejected: ", m.name
        else:
          echo "  FAIL not rejected: ", m.name, " (expected ", $m.expect, ")"
          printReport(r)
          result = false
      finally:
        writeFile(path, original)
  finally:
    removeDir(tmp)

proc main(): int =
  let repo = getCurrentDir()
  if not fileExists(repo / "src/isonim/core/owner.nim"):
    echo "check_design_notes: run from the repository root"
    return 1
  let specNames = siblingSpecNames(repo / "..")
  if "--self-test" in commandLineParams():
    echo "check_design_notes --self-test"
    if selfTest(repo, specNames):
      echo "check_design_notes --self-test: OK"
      return 0
    echo "check_design_notes --self-test: FAILED"
    return 1
  echo "check_design_notes: ", ListedModules.len, " modules, ",
    specNames.len, " specification names from sibling checkouts"
  let r = check(repo, ListedModules, specNames)
  printReport(r)
  if r.findings.len == 0:
    echo "check_design_notes: OK"
    return 0
  echo "check_design_notes: ", r.findings.len, " finding(s)"
  1

when isMainModule:
  quit(main())
