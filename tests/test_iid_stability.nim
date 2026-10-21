## Real compiler/source/SSR integration. No mocks: compare actual DSL output
## after edits at the same source path, with exact stamped-element counts.
import std/[os, osproc, strutils, unittest, sets]

const repo = currentSourcePath().parentDir.parentDir
let scratch = repo / "build/iid-stability"
createDir(scratch)
let fixture = scratch / "task_app.nim"
let original = readFile(repo / "tests/fixtures/stable_ids/task_app.nim")

proc compileMarkup(source: string; expected = 44): seq[string] =
  writeFile(fixture, source)
  let cmd = "nim c -r --hints:off -d:isServer -d:isonimStableIds --path:" &
    quoteShell(repo / "src") & " --path:" & quoteShell(repo / "../nim-everywhere/src") & " --path:" & quoteShell(repo / "../nim-faststreams") & " --path:" & quoteShell(repo / "../nim-stew") & " -d:iidProjectRoot=" & quoteShell(repo) &
    " --out:" & quoteShell(scratch / "app") & " " & quoteShell(fixture)
  let run = execCmdEx(cmd)
  doAssert run.exitCode == 0, run.output
  var offset = 0
  while true:
    let at = run.output.find("data-iid=\"", offset)
    if at < 0: break
    let start = at + "data-iid=\"".len
    let finish = run.output.find('"', start)
    result.add run.output[start ..< finish]
    offset = finish + 1
  doAssert result.len == expected, "expected " & $expected & " stamped controls, got " & $result.len & "\n" & run.output
  doAssert result.toHashSet.len == result.len, "duplicate iid"

suite "structural stable ids from actual DSL":
  test "unrelated lines and another component do not change identities":
    let baseline = compileMarkup(original)
    check compileMarkup("# unrelated line\n" & original) == baseline
    check compileMarkup(original.replace("var calls = 0", "proc unrelated(): string =\n  ui:\n    button: text \"elsewhere\"\n\nvar calls = 0")) == baseline
  test "explicit key survives sibling insertion":
    let baseline = compileMarkup(original)
    let inserted = compileMarkup(original.replace("      button(key = \"fixed\"", "      span: text \"new sibling\"\n      button(key = \"fixed\""))
    check inserted[^1] == baseline[^1]
  test "component rename changes every identity":
    let baseline = compileMarkup(original)
    let renamed = compileMarkup(original.replace("taskApp", "renamedTaskApp"))
    check renamed.toHashSet * baseline.toHashSet == initHashSet[string]()
  test "bare void controls are stamped":
    let ids = compileMarkup(original.replace("      ul:", "      input\n      ul:"), 45)
    check ids.len == 45
  test "adjacent natural loops and branches have distinct structural scopes":
    let loops = original.replace("      ul:", "      for a in 0 ..< 1:\n        button: text \"first loop\"\n      for b in 0 ..< 1:\n        button: text \"second loop\"\n      if true:\n        button: text \"branch\"\n      ul:")
    check compileMarkup(loops, 47).len == 47
  test "streaming SSR shares the same structural identities":
    let baseline = compileMarkup(original)
    let streaming = ("import faststreams/outputs\n" & original)
      .replace("  isomorphicUi(r):", "  let output = memoryOutput()\n  uiWrite(output.s):")
      .replace("\nwhen defined(js):\n  proc inspect", "\n  output.s.getOutput(string)\n\nwhen defined(js):\n  proc inspect")
    check compileMarkup(streaming) == baseline
  test "escaped handler attributes stamp non-control elements":
    let escaped = original.replace("button(key = \"fixed\", onclick = clicked)",
      "tdiv(key = \"fixed\", `onclick` = clicked)")
    check compileMarkup(escaped).len == 44

  test "authored data-iid is reserved across real renderers only with stable ids":
    # Compile actual renderer calls, including an otherwise unstamped div.
    # The flag-off control must compile the identical source successfully.
    for attribute in ["`data-iid`", "\"data-iid\"", "`DATA-IID`",
        "\"DATA-IID\"", "`data-IiD`", "\"data-IiD\""]:
      for element in ["tdiv", "button"]:
        for mode in ["client", "string", "stream"]:
          let markup = element & "(" & attribute & " = \"authored\"):\n    text \"reserved\""
          var source: string
          if mode == "client":
            source = "import isonim/dsl/ui\nimport isonim/web/web_renderer\nlet r = WebRenderer()\nlet node = ui(r):\n  " & markup & "\n"
          elif mode == "string":
            source = "import isonim/dsl/ui\nimport isonim/ssr/[renderer, escape, markers]\nlet html = ui:\n  " & markup & "\necho html\n"
          else:
            source = "import isonim/dsl/ui\nimport isonim/ssr/[renderer, escape, markers]\nimport faststreams/outputs\nlet output = memoryOutput()\nuiWrite(output.s):\n  " & markup & "\necho output.s.getOutput(string)\n"
          writeFile(fixture, source)
          let command = "nim " & (if mode == "client": "js" else: "c -d:isServer") &
            " --hints:off --path:" & quoteShell(repo / "src") &
            " --path:" & quoteShell(repo / "../nim-everywhere/src") &
            " --path:" & quoteShell(repo / "../nim-faststreams") &
            " --path:" & quoteShell(repo / "../nim-stew") &
            " --out:" & quoteShell(scratch / (if mode == "client": "reserved.js" else: "reserved"))
          let rejected = execCmdEx(command & " -d:isonimStableIds " & quoteShell(fixture))
          check rejected.exitCode != 0
          check "data-iid is reserved when isonimStableIds is enabled" in rejected.output
          let ordinary = execCmdEx(command & " " & quoteShell(fixture))
          doAssert ordinary.exitCode == 0, mode & " " & attribute & "\n" & ordinary.output
          if attribute == "`data-iid`":
            # Reserve exactly the HTML name, not an arbitrary attribute prefix.
            writeFile(fixture, source.replace("`data-iid`", "`data-iid-extra`"))
            let distinctAttribute = execCmdEx(command & " -d:isonimStableIds " & quoteShell(fixture))
            doAssert distinctAttribute.exitCode == 0, mode & " data-iid-extra\n" & distinctAttribute.output
