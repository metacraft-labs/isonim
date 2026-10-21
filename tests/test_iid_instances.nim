## Real compiler + SSR source edits. No mocks or replacement identity code.
import std/[os, osproc, strutils, sets, unittest, sequtils]
const repo = currentSourcePath().parentDir.parentDir
let scratch = repo / "build/iid-instances"
createDir(scratch)
let path = scratch / "instances.nim"
let original = readFile(repo / "tests/fixtures/stable_ids/instances.nim")

proc compile(source: string; flags = "-d:isonimStableIds"): tuple[code: int, output: string] =
  writeFile(path, source)
  let cmd = "nim c -r --hints:off -d:isServer " & flags &
    " --path:" & quoteShell(repo / "src") & " --path:" & quoteShell(repo / "../nim-everywhere/src") &
    " --path:" & quoteShell(repo / "../nim-faststreams") & " --path:" & quoteShell(repo / "../nim-stew") &
    " -d:iidProjectRoot=" & quoteShell(repo) & " --out:" & quoteShell(scratch / "app") & " " & quoteShell(path)
  let run = execCmdEx(cmd)
  (run.exitCode, run.output)

proc ids(source: string): seq[string] =
  let run = compile(source)
  doAssert run.code == 0, run.output
  var offset = 0
  while true:
    let at = run.output.find(" data-iid=\"", offset)
    if at < 0: break
    let start = at + " data-iid=\"".len
    let finish = run.output.find('"', start)
    result.add run.output[start ..< finish]
    offset = finish + 1
  doAssert result.len == 5, "expected five live reusable targets: " & run.output
  doAssert result.toHashSet.len == 5, "aliased reusable instances: " & $result

suite "reusable structural instance identity":
  test "repeated nested instances are unique and source-line independent":
    let baseline = ids(original)
    check ids(original.replace("renderToString(proc(): string = instances(0))", "instances(0)")) == baseline
    check ids("# unrelated line\n" & original) == baseline
    check ids(original.replace("proc leaf", "proc unrelated(): string = \"unused\"\n\nproc leaf")) == baseline
    check baseline.allIt(it.contains('@'))
  test "a keyed ancestor anchors nested call slots under sibling insertion":
    let baseline = ids(original)
    check ids(original.replace("      tdiv(key", "      span: text \"unrelated sibling\"\n      tdiv(key"))[^1] == baseline[^1]
  test "ordinary helper expressions share the raw call-slot contract":
    check ids(original.replace("raw leaf(r)", "leaf(r)").replace("raw branch(r)", "branch(r)")) == ids(original)
  test "streaming SSR uses exactly the same nested scopes":
    let stream = ("import faststreams/outputs\n" & original)
      .replace("proc instances(r: auto): auto =\n  isomorphicUi(r):", "proc instances(r: auto): auto =\n  let output = memoryOutput()\n  uiWrite(output.s):")
      .replace("\nwhen defined(js):\n  hydrate", "\n  output.s.getOutput(string)\n\nwhen defined(js):\n  hydrate")
    check ids(stream) == ids(original)
  test "ambiguous calls outside the DSL fail within a server render":
    let outside = original.replace("instances(0)", "leaf(0) & leaf(0)")
    let rejected = compile(outside)
    check rejected.code != 0
    check "duplicate live stable iid:" in rejected.output
    let ordinary = compile(outside, "")
    check ordinary.code == 0
    check "data-iid" notin ordinary.output

  test "default build erases the scope and its unused argument byte for byte":
    let probe = "import isonim/dsl/stable_ids\nproc noise(): string =\n  echo \"scope was evaluated\"\n  \"unused\"\necho withStableInstance(noise(), 7)\n"
    writeFile(path, probe)
    let command = "nim js --hints:off -d:release --stackTrace:off --lineTrace:off --path:" & quoteShell(repo / "src") & " --out:" & quoteShell(scratch / "default.js") & " " & quoteShell(path)
    let scoped = execCmdEx(command)
    doAssert scoped.exitCode == 0, scoped.output
    let bytes = readFile(scratch / "default.js")
    writeFile(path, probe.replace("withStableInstance(noise(), 7)", "7"))
    let plain = execCmdEx(command)
    doAssert plain.exitCode == 0, plain.output
    check readFile(scratch / "default.js") == bytes
    check "scope was evaluated" notin bytes

  test "colliding caller slots fail compilation even for unstamped wrappers":
    let duplicateSlots = original.replace("      raw branch(r)\n      raw branch(r)",
      "      tdiv(key = \"duplicate\"):\n        raw branch(r)\n      tdiv(key = \"duplicate\"):\n        raw branch(r)")
    let rejected = compile(duplicateSlots)
    check rejected.code != 0
    check "stable caller-scope collision:" in rejected.output
