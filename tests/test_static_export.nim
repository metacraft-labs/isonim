## isonim/static: exportSite, sitemap, robots and build.json, against the
## real file system. C only (the exporter writes files).
##
## The fixture is a small route set given in a scrambled order. It must
## export to the expected file tree, two exports of it (given in two
## different orders) must be byte-identical, and the exported
## `sitemap.xml` and `robots.txt` must equal the hand-written goldens in
## `tests/fixtures/static-export/golden/`, which were written from the
## sitemaps.org and robots.txt formats, not produced by this code.
##
## Falsifying mutation (run by hand when the suite was written): iterating
## the pages in hash-table order instead of sorted order in
## `exporter.orderPages` makes the golden sitemap comparison fail.
##
## No test doubles: every case writes and reads real directories under the
## system temp directory, removed at the end.

import std/[unittest, os, strutils, algorithm, sequtils]
import isonim/static

const
  baseUrl = "https://example.org"
  # Embedded at compile time, so the test binary reads no file it was not
  # built from.
  goldenSitemap = staticRead("fixtures/static-export/golden/sitemap.xml")
  goldenRobots = staticRead("fixtures/static-export/golden/robots.txt")

let scratch = getTempDir() / ("isonim-test-static-export-" & $getCurrentProcessId())

proc page(route: string; lastmod = ""; noindex = false): SitePage =
  SitePage(route: route, lastmod: lastmod, noindex: noindex,
           html: "<!doctype html><html><head><title>" & route &
                 "</title></head><body><h1>" & route & "</h1></body></html>\n")

proc fixturePages(): seq[SitePage] =
  ## Deliberately not in route order.
  @[
    page("/posts/hello-world", lastmod = "2026-10-21"),
    page("/tags/r&d"),
    page("/", lastmod = "2026-10-21T08:30:00Z"),
    page("/drafts/secret", noindex = true),
    page("/about/"),
    page("/404.html", noindex = true),
    page("/posts/2026/a-z", lastmod = "2026-10-01"),
  ]

proc fixtureFiles(pages: openArray[SitePage]): seq[SiteFile] =
  @[
    SiteFile(path: "sitemap.xml", content: renderSitemap(sitemapEntriesFor(pages, baseUrl))),
    SiteFile(path: "robots.txt", content: renderRobots(sitemapUrlFor(baseUrl))),
    SiteFile(path: "feed.xml", content: "<feed/>\n"),
    SiteFile(path: "assets/style.css", content: "body{margin:0}\n"),
  ]

const expectedTree = [
  "404.html",
  "about/index.html",
  "assets/style.css",
  "drafts/secret/index.html",
  "feed.xml",
  "index.html",
  "posts/2026/a-z/index.html",
  "posts/hello-world/index.html",
  "robots.txt",
  "sitemap.xml",
  "tags/r&d/index.html",
]

proc treeOnDisk(dir: string): seq[string] =
  for rel in walkDirRec(dir, relative = true):
    result.add rel.replace('\\', '/')
  result.sort(system.cmp[string])

proc siblingsOf(dir: string): seq[string] =
  ## Everything next to `dir` whose name starts with `dir`'s name: the
  ## staging and previous-output directories an export must not leave.
  let (parent, name) = splitPath(dir)
  for kind, p in walkDir(parent):
    let n = extractFilename(p)
    if n.startsWith(name) and n != name: result.add n

suite "isonim/static/exporter -- clean URLs":
  test "routes map to clean-URL files":
    check outputRelPath("/") == "index.html"
    check outputRelPath("/guide/dsl") == "guide/dsl/index.html"
    check outputRelPath("/guide/dsl/") == "guide/dsl/index.html"
    check outputRelPath("/404.html") == "404.html"
    check outputRelPath("/v1.2/guide") == "v1.2/guide/index.html"

  test "routes that are not absolute, escape the root or carry a query are refused":
    for bad in ["", "guide", "/../etc", "/a/../../b", "/a//b", "/a?b", "/a#b", "/a\\b", "//a", "/a//", "////"]:
      expect ExportError:
        discard outputRelPath(bad)

suite "isonim/static/exporter -- exportSite":
  setup:
    createDir(scratch)
  teardown:
    removeDir(scratch)

  test "a fixture route set exports to the expected file tree":
    let pages = fixturePages()
    let outDir = scratch / "site"
    let report = exportSite(pages, outDir, fixtureFiles(pages))
    check report.files == @expectedTree
    check treeOnDisk(outDir) == @expectedTree
    check report.pages.mapIt(it.route) ==
      @["/", "/404.html", "/about/", "/drafts/secret", "/posts/2026/a-z",
        "/posts/hello-world", "/tags/r&d"]
    check readFile(outDir / "about" / "index.html") == page("/about/").html
    check siblingsOf(outDir).len == 0

  test "sitemap.xml and robots.txt match the golden files byte for byte":
    let pages = fixturePages()
    let outDir = scratch / "site"
    discard exportSite(pages, outDir, fixtureFiles(pages))
    check readFile(outDir / "sitemap.xml") == goldenSitemap
    check readFile(outDir / "robots.txt") == goldenRobots

  test "two exports of the same site, given in different orders, are byte-identical":
    let pages = fixturePages()
    let reversedPages = pages.reversed
    let a = scratch / "a"
    let b = scratch / "b"
    discard exportSite(pages, a, fixtureFiles(pages))
    discard exportSite(reversedPages, b, fixtureFiles(reversedPages).reversed)
    let treeA = treeOnDisk(a)
    check treeA == treeOnDisk(b)
    check treeA.len == expectedTree.len
    for rel in treeA:
      check readFile(a / rel) == readFile(b / rel)

  test "an export replaces the previous output, leaving no stale file and no staging directory":
    let outDir = scratch / "site"
    createDir(outDir / "old")
    writeFile(outDir / "old" / "stale.html", "stale")
    let pages = fixturePages()
    discard exportSite(pages, outDir, fixtureFiles(pages))
    check not fileExists(outDir / "old" / "stale.html")
    check treeOnDisk(outDir) == @expectedTree
    check siblingsOf(outDir).len == 0

  test "a colliding route set raises before anything is written, and the previous output survives":
    let outDir = scratch / "site"
    let pages = fixturePages()
    discard exportSite(pages, outDir, fixtureFiles(pages))
    for collision in [@[page("/a"), page("/a/")],
                      @[page("/A"), page("/a")],
                      @[page("/feed.xml")]]:
      expect ExportError:
        discard exportSite(pages & collision, outDir, fixtureFiles(pages))
    expect ExportError: # a file that would need to be a directory
      discard exportSite(@[page("/x")], outDir, @[SiteFile(path: "x", content: "")])
    expect ExportError:
      discard exportSite(@[page("/")], outDir, @[SiteFile(path: "../escape", content: "")])
    check treeOnDisk(outDir) == @expectedTree
    check siblingsOf(outDir).len == 0

  test "a write that fails halfway leaves the previous output untouched":
    let outDir = scratch / "site"
    let pages = fixturePages()
    discard exportSite(pages, outDir, fixtureFiles(pages))
    let before = readFile(outDir / "index.html")
    # Passes validation, then fails in the middle of writing: the file
    # name is longer than any file system allows (255 bytes).
    let tooLong = SiteFile(path: "zz/" & repeat('n', 300) & ".txt", content: "x")
    expect CatchableError:
      discard exportSite(@[page("/new")], outDir, @[tooLong])
    check treeOnDisk(outDir) == @expectedTree
    check readFile(outDir / "index.html") == before
    check siblingsOf(outDir).len == 0

  test "readTreeFiles reads a directory as sorted site files under a prefix":
    let src = scratch / "static"
    createDir(src / "img")
    writeFile(src / "img" / "b.png", "B")
    writeFile(src / "a.txt", "A")
    let files = readTreeFiles(src, "assets/")
    check files.mapIt(it.path) == @["assets/a.txt", "assets/img/b.png"]
    check files.mapIt(it.content) == @["A", "B"]
    check readTreeFiles(scratch / "missing").len == 0

suite "isonim/static/sitemap and robots":
  test "sitemap entries follow export order and leave out noindex pages":
    check sitemapEntriesFor(fixturePages(), baseUrl) ==
      sitemapEntriesFor(fixturePages().reversed, baseUrl)
    check sitemapEntriesFor(fixturePages(), baseUrl).mapIt(it.loc) == @[
      "https://example.org/", "https://example.org/about/",
      "https://example.org/posts/2026/a-z", "https://example.org/posts/hello-world",
      "https://example.org/tags/r&d"]

  test "without lastmod, the sitemap is exactly the format isonim-docs has always written":
    check renderSitemap([sitemapEntry("https://docs.example.com/", "/guide")]) ==
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
      "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n" &
      "  <url><loc>https://docs.example.com/guide</loc></url>\n" &
      "</urlset>\n"

  test "lastmod must be a W3C Datetime":
    for good in ["2026-10-21", "2026-10-21T08:30Z", "2026-10-21T08:30:00Z",
                 "2026-10-21T08:30:00.5+02:00", "2026-10-21T23:59:59-05:00"]:
      check isW3cDatetime(good)
    for bad in ["2026", "2026-10", "21-10-2026", "2026-13-01", "2026-10-21T08:30",
                "2026-10-21 08:30Z", "2026-10-21T25:00Z", "2026-10-21T23:59:60-05:00",
                "2026-10-21T23:59:60.5Z", "2026-10-21T08:30:00.Z", "yesterday"]:
      check not isW3cDatetime(bad)
      expect SitemapError:
        discard renderSitemap([SitemapEntry(loc: "/", lastmod: bad)])

  test "robots.txt: the default policy, custom groups, and no line breaks in values":
    check renderRobots("/sitemap.xml") == "User-agent: *\nAllow: /\nSitemap: /sitemap.xml\n"
    check renderRobots([RobotsGroup(userAgent: "*", disallow: @["/drafts/"]),
                        RobotsGroup(userAgent: "ExampleBot", disallow: @["/"])]) ==
      "User-agent: *\nDisallow: /drafts/\n\nUser-agent: ExampleBot\nDisallow: /\n"
    expect ValueError:
      discard renderRobots([RobotsGroup(userAgent: "*", disallow: @["/a\nAllow: /"])])

  test "joinSiteUrl never doubles or invents slashes or hosts":
    check joinSiteUrl("https://example.org/", "/a") == "https://example.org/a"
    check joinSiteUrl("https://example.org", "a") == "https://example.org/a"
    check joinSiteUrl("https://example.org", "") == "https://example.org/"
    check joinSiteUrl("", "/a") == "/a"

suite "isonim/static/buildinfo -- build.json":
  setup:
    createDir(scratch)
  teardown:
    removeDir(scratch)

  test "build.json has a fixed layout, with components sorted by name":
    let info = SiteBuildInfo(generator: "example-gen 1.0", sourceRevision: "abc123",
      components: @[BuildComponent(name: "theme", revision: "t1"),
                    BuildComponent(name: "isonim", revision: "i1")],
      sourceDateEpoch: 1761004800, outputHash: "sha256-00")
    check renderBuildJson(info) ==
      "{\n" &
      "  \"generator\": \"example-gen 1.0\",\n" &
      "  \"sourceRevision\": \"abc123\",\n" &
      "  \"components\": [\n" &
      "    {\"name\": \"isonim\", \"revision\": \"i1\"},\n" &
      "    {\"name\": \"theme\", \"revision\": \"t1\"}\n" &
      "  ],\n" &
      "  \"sourceDateEpoch\": 1761004800,\n" &
      "  \"outputHash\": \"sha256-00\"\n" &
      "}\n"
    check renderBuildJson(SiteBuildInfo(sourceDateEpoch: -1)).contains("\"components\": [],\n  \"sourceDateEpoch\": null,")

  test "the tree hash ignores input order and build.json, and changes with any byte":
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let files = @[("a.html", "A"), ("b/c.css", "C")]
    check treeHashOf(files) == treeHashOf(files.reversed)
    check treeHashOf(files) != treeHashOf(@[("a.html", "A"), ("b/c.css", "D")])
    let pages = fixturePages()
    let outDir = scratch / "site"
    discard exportSite(pages, outDir, fixtureFiles(pages))
    let h = treeHash(outDir)
    writeFile(outDir / "build.json", "{}")
    check treeHash(outDir) == h
    writeFile(outDir / "feed.xml", "<feed></feed>\n")
    check treeHash(outDir) != h

  test "SOURCE_DATE_EPOCH is honoured, absent is -1, and garbage is an error":
    let saved = getEnv("SOURCE_DATE_EPOCH")
    let had = existsEnv("SOURCE_DATE_EPOCH")
    try:
      putEnv("SOURCE_DATE_EPOCH", "1761004800")
      check sourceDateEpochFromEnv() == 1761004800'i64
      delEnv("SOURCE_DATE_EPOCH")
      check sourceDateEpochFromEnv() == -1
      putEnv("SOURCE_DATE_EPOCH", "17610048OO")
      expect ValueError:
        discard sourceDateEpochFromEnv()
    finally:
      if had: putEnv("SOURCE_DATE_EPOCH", saved) else: delEnv("SOURCE_DATE_EPOCH")

  test "writing build.json into two identical exports gives identical files":
    let pages = fixturePages()
    let info = SiteBuildInfo(generator: "example-gen 1.0", sourceRevision: "abc123",
                             sourceDateEpoch: 1761004800)
    var written: seq[string]
    for name in ["a", "b"]:
      let outDir = scratch / name
      discard exportSite(pages, outDir, fixtureFiles(pages))
      let rec = writeBuildInfo(outDir, info)
      check rec.outputHash.startsWith("sha256-")
      written.add readFile(outDir / "build.json")
    check written[0] == written[1]

  test "different real trees with exceptional filenames have distinct hashes":
    let a = scratch / "ordinary"
    let b = scratch / "injected"
    createDir(a)
    createDir(b)
    writeFile(a / "a", "A")
    writeFile(a / "b", "B")
    writeFile(b / ("a\n" & sha256Hex("B") & "  b"), "A")
    check treeHash(a) != treeHash(b)
    let slash = scratch / "slash"
    let backslash = scratch / "backslash"
    createDir(slash / "a")
    createDir(backslash)
    writeFile(slash / "a/b", "A")
    writeFile(backslash / "a\\b", "A")
    check treeHash(slash) != treeHash(backslash)
    check treeHash(backslash) == treeHashOf(@[("a\\b", "A")])
    let carriageReturn = scratch / "carriage-return"
    createDir(carriageReturn)
    writeFile(carriageReturn / "a\rb", "A")
    check treeHash(carriageReturn) == treeHashOf(@[("a\rb", "A")])
    check treeHash(carriageReturn) != treeHash(backslash)

import std/[sets, json]
import std/posix
import isonim/static/exporter
import isonim/static/assets
let regressionScratch = getTempDir() / ("isonim-static-boundaries-" & $getCurrentProcessId())
createDir(regressionScratch)
suite "exporter ownership and asset boundaries":
  test "reserved sibling directories cannot be silently erased":
    let target = regressionScratch / "site"
    let other = target & stagingSuffix
    createDir(other)
    writeFile(other / "important.txt", "unrelated data")
    discard exportSite([SitePage(route: "/", html: "ok")], target)
    check fileExists(other / "important.txt")
  test "staging symlinks must not erase their target":
    let target = regressionScratch / "symlink-site"
    let outside = regressionScratch / "outside"
    createDir(outside)
    writeFile(outside / "important.txt", "unrelated data")
    createSymlink(outside, target & stagingSuffix)
    try:
      discard exportSite([SitePage(route: "/", html: "ok")], target)
    except CatchableError: discard
    check fileExists(outside / "important.txt")
  test "asset names cannot overwrite another original before reading it":
    let site = regressionScratch / "assets-site"
    createDir(site / "assets")
    let collision = hashedAssetName("a.0", "A")
    writeFile(site / "assets/a.0", "A")
    writeFile(site / "assets" / collision, "B")
    let rewrites = hashAndPurgeAssets(site, initHashSet[string]())
    check readFile(site / "assets" / hashedAssetName(collision, "B")) == "B"
    check readFile(site / "assets" / hashedAssetName("a.0", "A")) == "A"
    let manifest = parseJson(readFile(site / "asset-manifest.json"))
    check manifest["assets/a.0"].getStr == "assets/" & hashedAssetName("a.0", "A")
    check manifest["assets/" & collision].getStr == "assets/" & hashedAssetName(collision, "B")
    check rewrites.len == 2
  test "independent handles survive another publisher and a failed publication":
    let target = regressionScratch / "concurrent"
    let a = beginStaging(target)
    writeFile(a.path / "a.txt", "A")
    let b = beginStaging(target)
    check a.path != b.path
    check readFile(a.path / "a.txt") == "A"
    writeFile(b.path / "b.txt", "B")
    commitStaging(a, target)
    check readFile(b.path / "b.txt") == "B"
    expect ExportError: commitStaging(b, regressionScratch / "wrong")
    check readFile(target / "a.txt") == "A"
    commitStaging(b, target)
    discardStaging(a) # a closed handle cannot affect the second output
    check readFile(target / "b.txt") == "B"
    check not fileExists(target / "a.txt")

  test "output and replaced stage symlinks never traverse their targets":
    let outside = regressionScratch / "safe"
    createDir(outside)
    writeFile(outside / "important", "safe")
    let target = regressionScratch / "linked-output"
    createSymlink(outside, target)
    expect ExportError: discard exportSite([page("/")], target)
    check readFile(outside / "important") == "safe"
    let stage = beginStaging(regressionScratch / "replace-stage")
    let stagePath = stage.path
    removeDir(stagePath)
    createSymlink(outside, stagePath)
    expect ExportError: commitStaging(stage, regressionScratch / "replace-stage")
    discardStaging(stage)
    check readFile(outside / "important") == "safe"

  test "cleanup failure reports that publication succeeded":
    let target = regressionScratch / "cleanup"
    createDir(target / "locked")
    writeFile(target / "locked/file", "old")
    setFilePermissions(target / "locked", {fpUserRead, fpUserExec})
    let stage = beginStaging(target)
    let obsolete = stage.path
    writeFile(stage.path / "index.html", "new")
    try:
      expect ExportCleanupError:
        commitStaging(stage, target)
      check readFile(target / "index.html") == "new"
      check dirExists(obsolete / "locked")
    finally:
      if dirExists(obsolete / "locked"):
        setFilePermissions(obsolete / "locked", {fpUserRead, fpUserWrite, fpUserExec})
      if dirExists(obsolete): removeDir(obsolete)

  test "asset destination collisions fail before changing originals":
    let site = regressionScratch / "collision"
    createDir(site / "assets")
    writeFile(site / "assets/a.0", "A")
    let destination = site / "assets" / hashedAssetName("a.0", "A")
    createDir(destination)
    writeFile(destination / "sentinel", "unrelated")
    expect ValueError:
      discard hashAndPurgeAssets(site, initHashSet[string]())
    check readFile(site / "assets/a.0") == "A"
    check readFile(destination / "sentinel") == "unrelated"
    check not fileExists(site / "asset-manifest.json")

  test "atomic publication has no missing-directory interval for a concurrent reader":
    let target = regressionScratch / "atomic"
    discard exportSite([SitePage(route: "/", html: repeat('A', 8192))], target)
    var ready: array[2, cint]
    var finished: array[2, cint]
    require pipe(ready) == 0
    require pipe(finished) == 0
    let child = fork()
    require child >= 0
    if child == 0:
      discard close(ready[0])
      discard close(finished[1])
      discard fcntl(finished[0], F_SETFL, O_NONBLOCK)
      var signal = 'r'
      discard posix.write(ready[1], addr signal, 1)
      var reads = 0
      var failed = false
      while posix.read(finished[0], addr signal, 1) < 0:
        if not dirExists(target): failed = true
        try:
          let bytes = readFile(target / "index.html")
          if bytes != repeat('A', 8192) and bytes != repeat('B', 8192): failed = true
        except CatchableError: failed = true
        inc reads
      quit(if failed or reads == 0: 1 else: 0)
    discard close(ready[1])
    discard close(finished[0])
    var signal: char
    var status: cint
    try:
      require posix.read(ready[0], addr signal, 1) == 1
      for i in 0..<200:
        discard exportSite([SitePage(route: "/", html: repeat(if i mod 2 == 0: 'B' else: 'A', 8192))], target)
    finally:
      # Even a publication failure or assertion must stop and reap our
      # reader; mutations must not leave a child spinning in the background.
      discard posix.write(finished[1], addr signal, 1)
      discard close(finished[1])
      discard close(ready[0])
      check waitpid(child, status, 0) == child
    check WIFEXITED(status)
    check WEXITSTATUS(status) == 0
removeDir(regressionScratch)
