## isonim/content/frontmatter -- splitting front matter off a file, and the
## documented YAML subset. Dual-target: `nim c -r` and `nim js -r` must
## both pass.
##
## The `splitFrontMatter` cases moved unchanged from isonim-docs' content
## loader suite with the function. The rest cover the subset the module
## documents, case by case: scalars (plain, quoted, escaped, commented),
## flow and block lists, flow and block one-level maps, unknown keys kept
## in source order, the typed accessors, and every construct the subset
## refuses -- each refusal must name the file line, so a test asserts the
## line, not just that something was raised. No test doubles.

import std/unittest
import isonim/content/frontmatter

proc errLine(raw: string): int =
  ## The file line a FrontMatterError names for a whole file `raw`, or -1
  ## when parsing succeeds.
  try:
    discard readFrontMatter(raw)
    -1
  except FrontMatterError as e:
    e.line

suite "isonim/content/frontmatter -- splitFrontMatter":
  test "splitFrontMatter extracts a leading '---' block and reports the body's start line":
    let (frontRaw, bodyRaw, bodyLine) = splitFrontMatter(
      "---\ntitle: Getting Started\nsection: guide\n---\n# Getting Started\n\nBody.")
    check frontRaw == "title: Getting Started\nsection: guide"
    check bodyRaw == "# Getting Started\n\nBody."
    check bodyLine == 5

  test "splitFrontMatter returns an empty front matter and line 1 when there's no leading '---'":
    let (frontRaw, bodyRaw, bodyLine) = splitFrontMatter("# Plain Page\n\nNo front matter here.")
    check frontRaw == ""
    check bodyRaw == "# Plain Page\n\nNo front matter here."
    check bodyLine == 1

  test "splitFrontMatter treats an unterminated '---' block as no front matter at all":
    let (frontRaw, bodyRaw, bodyLine) = splitFrontMatter("---\ntitle: Oops\n\n# Body without a closing marker")
    check frontRaw == ""
    check bodyRaw == "---\ntitle: Oops\n\n# Body without a closing marker"
    check bodyLine == 1

suite "isonim/content/frontmatter -- scalars":
  test "plain scalars are the rest of the line, trimmed, less a ' #' comment":
    let fm = parseFrontMatterBlock("title: Hello world  \nslug: hello # the URL\nurl: http://a.b/#frag")
    check fm.getStr("title") == "Hello world"
    check fm.getStr("slug") == "hello"
    check fm.getStr("url") == "http://a.b/#frag"

  test "the documented leniency: a ': ' inside a plain scalar is part of it":
    check parseFrontMatterBlock("description: Note: read this first").getStr("description") ==
      "Note: read this first"

  test "single-quoted scalars keep '#' and ': ' and read '' as a quote":
    let fm = parseFrontMatterBlock("a: 'it''s # not a comment: really'  # but this is")
    check fm.getStr("a") == "it's # not a comment: really"

  test "double-quoted scalars decode escapes, including \\u":
    let fm = parseFrontMatterBlock("a: \"say \\\"hi\\\"\\n\\tthen \\u00e9\\\\\"")
    check fm.getStr("a") == "say \"hi\"\n\tthen \u00e9\\"

  test "an empty value with nothing under it is the empty scalar":
    let fm = parseFrontMatterBlock("a:\nb: # just a comment\nc: x")
    check fm["a"].kind == fvScalar
    check fm.getStr("a") == ""
    check fm.getStr("b") == ""
    check fm.getStr("c") == "x"

  test "comment lines and blank lines are skipped":
    let fm = parseFrontMatterBlock("# a comment\n\n   # an indented comment\ntitle: T\n")
    check fm.keys == @["title"]

suite "isonim/content/frontmatter -- lists and one-level maps":
  test "a flow list, with quoted items that contain commas":
    let fm = parseFrontMatterBlock("tags: [nim, \"web, ui\", 'x']")
    check fm["tags"].kind == fvList
    check fm.getList("tags") == @["nim", "web, ui", "x"]

  test "an empty flow list":
    check parseFrontMatterBlock("tags: []").getList("tags").len == 0

  test "a block list, indented or at the key's column":
    let fm = parseFrontMatterBlock("tags:\n  - nim\n  - \"a: b\"\ncats:\n- one\n- two # c\nafter: x")
    check fm.getList("tags") == @["nim", "a: b"]
    check fm.getList("cats") == @["one", "two"]
    check fm.getStr("after") == "x"

  test "a flow map and a block map keep their entries in source order":
    let fm = parseFrontMatterBlock(
      "author: {name: Ada, url: \"/about/\"}\nseo:\n  noindex: true\n  canonical: https://x.y/z\n")
    check fm["author"].kind == fvMap
    check fm.getMap("author") == @[FrontMatterPair(key: "name", value: "Ada"),
                                   FrontMatterPair(key: "url", value: "/about/")]
    check fm.getMap("seo") == @[FrontMatterPair(key: "noindex", value: "true"),
                                FrontMatterPair(key: "canonical", value: "https://x.y/z")]

  test "an absent or empty key reads as an empty list or map":
    let fm = parseFrontMatterBlock("tags:\nmeta:")
    check fm.getList("tags").len == 0
    check fm.getMap("meta").len == 0
    check fm.getList("missing").len == 0
    check fm.getMap("missing").len == 0

suite "isonim/content/frontmatter -- keys, lines and unknown keys":
  test "every key is kept in source order, unknown ones included, with its line":
    let (fm, body, bodyLine) = readFrontMatter(
      "---\ntitle: T\nmood: sunny\ntags: [a]\nseries:\n  name: S\n  order: 2\n---\nBody")
    check fm.keys == @["title", "mood", "tags", "series"]
    check fm.field("title").line == 2
    check fm.field("mood").line == 3
    check fm.field("series").line == 5
    check body == "Body"
    check bodyLine == 9

  test "without() drops the keys a consumer reads itself and keeps the rest in order":
    let fm = parseFrontMatterBlock("title: T\nmood: sunny\ndraft: true\nweather: [rain]")
    let extra = fm.without(["title", "draft"])
    check extra.keys == @["mood", "weather"]
    check extra.getList("weather") == @["rain"]

  test "a file with no front matter reads as an empty FrontMatter":
    let (fm, body, bodyLine) = readFrontMatter("# Title\n\nText")
    check fm.len == 0
    check body == "# Title\n\nText"
    check bodyLine == 1

  test "missing keys: [] raises KeyError, the getters return their defaults":
    let fm = parseFrontMatterBlock("a: 1")
    expect KeyError:
      discard fm["b"]
    check fm.getStr("b", "d") == "d"
    check fm.getBool("b", true) == true
    check fm.getInt("b", 7) == 7
    check "a" in fm
    check "b" notin fm

suite "isonim/content/frontmatter -- typed accessors":
  test "getBool reads the YAML 1.2 core-schema booleans":
    let fm = parseFrontMatterBlock("a: true\nb: False\nc: TRUE\nd: false")
    check fm.getBool("a")
    check not fm.getBool("b")
    check fm.getBool("c")
    check not fm.getBool("d")

  test "getBool and getInt refuse other text, naming the line":
    let fm = parseFrontMatterBlock("draft: yes\norder: two\nn: -12", firstLine = 2)
    check fm.getInt("n") == -12
    try:
      discard fm.getBool("draft")
      check false
    except FrontMatterError as e:
      check e.line == 2
    try:
      discard fm.getInt("order")
      check false
    except FrontMatterError as e:
      check e.line == 3

  test "asking for the wrong kind is an error, and a scalar is never split into a list":
    let fm = parseFrontMatterBlock("tags: a, b\nlist: [x]\nmap: {k: v}")
    check fm.getStr("tags") == "a, b"
    expect FrontMatterError:
      discard fm.getList("tags")
    expect FrontMatterError:
      discard fm.getStr("list")
    expect FrontMatterError:
      discard fm.getList("map")
    expect FrontMatterError:
      discard fm.getMap("list")

suite "isonim/content/frontmatter -- outside the subset: errors name the file line":
  test "nesting deeper than one level":
    check errLine("---\na:\n  b:\n    c: d\n---\n") == 3
    check errLine("---\na:\n  b: c\n    d: e\n---\n") == 4
    check errLine("---\na:\n  b: [x]\n---\n") == 3
    check errLine("---\na:\n  - [x, y]\n---\n") == 3
    check errLine("---\na: [x, [y]]\n---\n") == 2

  test "mixing a list and a map under one key":
    check errLine("---\na:\n  - x\n  b: c\n---\n") == 4
    check errLine("---\na:\n  b: c\n  - x\n---\n") == 4

  test "tabs, block scalars, anchors, aliases and tags":
    check errLine("---\na:\n\t- x\n---\n") == 3
    check errLine("---\nbody: |\n  text\n---\n") == 2
    check errLine("---\nbody: >\n  text\n---\n") == 2
    check errLine("---\na: &anchor x\n---\n") == 2
    check errLine("---\na: *anchor\n---\n") == 2
    check errLine("---\na: !!str x\n---\n") == 2

  test "duplicate keys, at the top level and inside a map":
    check errLine("---\na: 1\nb: 2\na: 3\n---\n") == 4
    check errLine("---\nm:\n  k: 1\n  k: 2\n---\n") == 4
    check errLine("---\nm: {k: 1, k: 2}\n---\n") == 2

  test "an indented line with no key above it, and a line that is not key: value":
    check errLine("---\n  a: b\n---\n") == 2
    check errLine("---\ntitle: T\njust words\n---\n") == 3

  test "unterminated quotes and flow collections, and junk after a quote":
    check errLine("---\na: \"open\n---\n") == 2
    check errLine("---\na: 'open\n---\n") == 2
    check errLine("---\na: [x, y\n---\n") == 2
    check errLine("---\na: {k: v\n---\n") == 2
    check errLine("---\na: \"x\" y\n---\n") == 2

  test "bad escapes in a double-quoted string":
    check errLine("---\na: \"\\q\"\n---\n") == 2
    check errLine("---\na: \"\\u12\"\n---\n") == 2
    check errLine("---\na: \"\\uD800\"\n---\n") == 2

  test "well-formed front matter raises nothing (control for the cases above)":
    check errLine("---\na:\n  b: c\nl:\n  - x\nf: [1, 2]\nm: {k: v}\nq: \"\\u00e9\"\n---\nbody") == -1
