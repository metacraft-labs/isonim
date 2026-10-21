## No mocks: real typed reads, reactive roots, and temporary filesystem exports.
import std/[algorithm, json, os, osproc, strutils, tables, tempfiles, sequtils, unittest]
import isonim/experiments
import isonim/core/owner
import isonim/ssr/export_permutations
import isonim/ssr/canonical

type
  First {.experimentKey: "constructor".} = enum fControl, fOther
  Second {.experimentKey: "__proto__".} = enum sControl, sOther, sThird
  Third {.experimentKey: "../%,=λ".} = enum tControl, tOther, tThird

proc weights(_: typedesc[Second]): seq[int] = @[50, 25, 25]
proc window(_: typedesc[Second]): tuple[start, finish: string] =
  ("2026-10-01", "2026-11-01")

proc render(route: string; assignment: ExperimentAssignment): string =
  var content = "plain"
  createRoot(proc(dispose: proc()) =
    defer: dispose()
    beginExperiments(assignment)
    if route == "/two":
      content = $useExperiment[First]() & $useExperiment[Second]()
    elif route == "/conditional":
      let first = useExperiment[First]()
      content = $first
      if first == fOther: content.add $useExperiment[Third]()
    elif route == "/nine":
      content = $useExperiment[Second]() & $useExperiment[Third]()
    elif route == "/markup":
      content = $useExperiment[First]()
  )
  if route == "/markup":
    return "<!doctype html><HTML><HEAD><!-- </head> -->" &
      "<script>globalThis.headLiteral='</head>';globalThis.openLiteral='</nope';</script>" &
      "<script><!--\n/* <script> */\nglobalThis.doubleLiteral='</script>';globalThis.afterDouble='</head>';\n//-->\n</script>" &
      "<style>/* </head> */body{color:red}</style>" &
      "<meta content=\"</head>\"><LINK data-hk='r3' data-test='a>b' nonce='n' rel='CANONICAL' href='/__x/wrong/'>" &
      "<link href='/wrong' rel='alternate canoni&#99;al'></HEAD><body>" & content & "</body></HTML>"
  "<html><head></head><body>" & content & "</body></html>"

suite "bounded experiment static exports":
  test "exact emitted files and canonical links for the Cartesian product":
    let dir = createTempDir("isonim-permutations-", "")
    defer: removeDir(dir)
    let exported = exportExperimentRoutes(dir, "https://example.test", ["/plain", "/two"], render)
    var expected = @[dir / "plain/index.html", dir / "two/index.html", dir / "experiments-routes.json"]
    for a in 0..1:
      for b in 0..2:
        expected.add dir / "__x" / ("~5f5f70726f746f5f5f=" & $b & ",~636f6e7374727563746f72=" & $a) / "two/index.html"
    var actual: seq[string]
    for path in walkDirRec(dir): actual.add path
    actual.sort()
    expected.sort()
    check actual.len == 9
    check actual == expected
    var reported = exported.files
    reported.sort()
    check reported == expected
    for path in actual:
      if path.endsWith(".html"):
        let route = if "/plain/" in path: "/plain" else: "/two"
        check readFile(path).contains("<link rel=\"canonical\" href=\"https://example.test" & route & "\">")
    check exported.routes["/plain"].len == 0
    check exported.routes["/two"]["constructor"]["arms"] == %*["fControl", "fOther"]
    check exported.routes["/two"]["__proto__"]["weights"] == %*[50, 25, 25]
    check exported.routes["/two"]["__proto__"]["window"] == %*{"start": "2026-10-01", "end": "2026-11-01"}
    check exported.routes["/two"]["constructor"]["window"].kind == JNull
    for _, descriptor in exported.routes["/two"]:
      check descriptor.len == 3 # arms, weights, window; never compiler source metadata
    check "callSite" notin readFile(dir / "experiments-routes.json")
    check currentSourcePath() notin readFile(dir / "experiments-routes.json")

  test "conditional reads discover a stable full product":
    let dir = createTempDir("isonim-conditional-", "")
    defer: removeDir(dir)
    let exported = exportExperimentRoutes(dir, "https://example.test", ["/conditional"], render)
    check exported.files.len == 8 # six variants, canonical, manifest
    check exported.routes["/conditional"].len == 2
    var bodies: seq[string]
    for path in exported.files:
      if path.endsWith(".html"): bodies.add readFile(path)
    check bodies.len == 7
    check bodies.anyIt("tThird" in it)
    let urls = currentSourcePath().parentDir / "check_export_urls.py"
    check execShellCmd("python3 " & quoteShell(urls) & " " & quoteShell(dir)) == 0

  test "nine combinations refuse before route emission":
    let dir = createTempDir("isonim-cap-", "")
    defer: removeDir(dir)
    expect ValueError:
      discard exportExperimentRoutes(dir, "https://example.test", ["/nine"], render)
    check not dirExists(dir / "__x")
    check not fileExists(dir / "nine/index.html")

  test "key encoding has no URI escapes, traversal or delimiters":
    var seen: seq[string]
    for key in ["/", ",", "=", "%", "λ", "..", "constructor", "__proto__"]:
      let encoded = comboKey(key)
      check encoded notin seen
      seen.add encoded
      check encoded[0] == '~'
      for c in encoded[1..^1]: check c in {'0'..'9', 'a'..'f'}
    let fixtures = parseFile(currentSourcePath().parentDir / "fixtures/export_combos.json")
    check fixtures.len == 2
    for fixture in fixtures:
      var assignment = initTable[string, int]()
      for key, arm in fixture["assign"]: assignment[key] = arm.getInt()
      check experimentCombo(assignment) == fixture["combo"].getStr()

  test "route traversal and non-path input are refused":
    let dir = createTempDir("isonim-invalid-route-", "")
    defer: removeDir(dir)
    for route in ["/../outside", "/a/../b", "relative", "/__x/test",
                  "/a?b", "/a#b", "/%2e%2e/a", "/a\\b", "", "//a", "/x/"]:
      expect ValueError:
        discard exportExperimentRoutes(dir, "https://example.test", [route], render)
    var files: seq[string]
    for path in walkDirRec(dir): files.add path
    check files.len == 0
    expect ValueError:
      discard exportExperimentRoutes(dir, "https://example.test", ["/same", "/same"], render)
    check not fileExists(dir / "same/index.html")

  test "canonical links preserve script, style, comments and quoted attributes":
    check withCanonicalUrl("<head><link data-hk='r4' rel=canonical href='/old'></head>", "https://example.test/a'b&c") ==
      "<head><link data-hk='r4' rel=canonical href='https://example.test/a&#39;b&amp;c'></head>"
    check withCanonicalUrl("<head><link data-hk='r4' rel=canonical href=/old></head>", "https://example.test/a") ==
      "<head><link data-hk='r4' rel=canonical href=\"https://example.test/a\"></head>"
    check withCanonicalUrl("<head><link data-hk='r4' rel=canonical /></head>", "https://example.test/a") ==
      "<head><link data-hk='r4' rel=canonical  href=\"https://example.test/a\"/></head>"
    let dir = createTempDir("isonim-canonical-", "")
    defer: removeDir(dir)
    let exported = exportExperimentRoutes(dir, "https://example.test", ["/markup"], render)
    check exported.files.len == 4 # canonical, two arms and manifest
    for path in exported.files:
      if path.endsWith(".html"):
        let html = readFile(path)
        check html.count("<LINK data-hk='r3' data-test='a>b' nonce='n' rel='CANONICAL' href='https://example.test/markup'>") == 1
        check html.count("https://example.test/markup") == 1
        check "<script>globalThis.headLiteral='</head>';globalThis.openLiteral='</nope';</script>" in html
        check "<style>/* </head> */body{color:red}</style>" in html
        check "<!-- </head> -->" in html
        check "<meta content=\"</head>\">" in html
        check "/__x/wrong/" notin html
        check "href='/wrong'" notin html
    when defined(exportPermutationBrowser):
      # Separate browser target; the original native command has no browser
      # prerequisite. This target additionally executes the emitted JavaScript.
      let browser = currentSourcePath().parentDir / "test_export_canonical.mjs"
      check execShellCmd("node " & quoteShell(browser) & " " & quoteShell(dir)) == 0
