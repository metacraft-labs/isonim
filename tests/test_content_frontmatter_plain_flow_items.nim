## isonim/content/frontmatter -- a quote character inside a plain flow item
## is part of the item. Dual-target: `nim c -r` and `nim js -r`.
##
## The property. The module documents a subset of YAML 1.2 in which the
## items of a flow list and the values of a one-level flow map are scalars,
## plain or quoted, and it promises that anything outside the subset is "a
## `FrontMatterError` that names the line, never a silent misreading". In
## YAML 1.2 a `'` or a `"` opens a quoted scalar only as the FIRST character
## of a scalar. Later in a plain scalar it is ordinary text, and in flow
## context a plain scalar ends only at `,`, `[`, `]`, `{` or `}` (YAML 1.2.2,
## 7.3.3 "Plain Style"). So `[it's, don't]` is the two items `it's` and
## `don't`, exactly as the block list `- it's` / `- don't` is, and
## `{name: O'Brien, url: /o'b/}` has the two entries `name` and `url`.
##
## What it guards against: taking a flow collection apart at its commas
## while treating a quote character at ANY position as the start of a quoted
## string. Two plain items that each hold the same quote character are then
## joined into one item, comma included, and in a map the second key is
## lost, both without an error; a single such character is reported as an
## unterminated quoted string that the text does not contain.
##
## Layout. The controls come first. They pin the harness (the helpers report
## a value as a value and an error as an error) and the neighbouring
## behaviour that has to stay as it is: quoted flow items, a comma inside a
## quoted item, two quote characters inside ONE plain item, and the same
## scalars written in block form. If a control fails, the cases after it say
## nothing about the property.
##
## No test doubles: every case goes through `parseFrontMatterBlock` and the
## public accessors `getList`, `getMap` and `getStr`.

import std/unittest
import isonim/content/frontmatter

type
  ListRead = tuple[error: string, items: seq[string]]
  MapRead = tuple[error: string, entries: seq[FrontMatterPair]]

proc readList(src, key: string): ListRead =
  ## The list the reader builds for `key` of the front matter block `src`,
  ## or the message of the `FrontMatterError` it raised. A value, so that a
  ## failing `check` prints what the reader actually produced.
  try:
    result.items = parseFrontMatterBlock(src).getList(key)
  except FrontMatterError as e:
    result.error = e.msg

proc readMap(src, key: string): MapRead =
  ## `readList` for a one-level map.
  try:
    result.entries = parseFrontMatterBlock(src).getMap(key)
  except FrontMatterError as e:
    result.error = e.msg

proc pair(key, value: string): FrontMatterPair =
  FrontMatterPair(key: key, value: value)

suite "isonim/content/frontmatter -- flow items: controls":
  test "the helpers report a value as a value and an error as an error":
    check readList("tags: [nim, web]", "tags") == (error: "", items: @["nim", "web"])
    check readMap("author: {name: Ada}", "author") ==
      (error: "", entries: @[pair("name", "Ada")])
    let badList = readList("tags: [nim, web", "tags")
    check badList.error.len > 0
    check badList.items.len == 0
    let badMap = readMap("author: {name: Ada", "author")
    check badMap.error.len > 0
    check badMap.entries.len == 0

  test "quoted flow items stay quoted scalars, and a comma inside one does not split it":
    check readList("tags: [nim, \"web, ui\", 'x']", "tags") ==
      (error: "", items: @["nim", "web, ui", "x"])
    check readMap("author: {name: Ada, url: \"/about/\"}", "author") ==
      (error: "", entries: @[pair("name", "Ada"), pair("url", "/about/")])

  test "two quote characters inside ONE plain flow item are part of that item":
    check readList("tags: [rock 'n' roll, jazz]", "tags") ==
      (error: "", items: @["rock 'n' roll", "jazz"])

  test "in block form the same scalars are plain: a quote after the first character is text":
    check parseFrontMatterBlock("title: it's").getStr("title") == "it's"
    check readList("tags:\n  - it's\n  - don't", "tags") ==
      (error: "", items: @["it's", "don't"])
    check readMap("author:\n  name: O'Brien\n  url: /o'b/", "author") ==
      (error: "", entries: @[pair("name", "O'Brien"), pair("url", "/o'b/")])

suite "isonim/content/frontmatter -- a quote inside a plain flow item is part of the item":
  test "an apostrophe in each of two flow-list items leaves two items":
    let r = readList("tags: [it's, don't]", "tags")
    check r.error == ""
    check r.items == @["it's", "don't"]

  test "an apostrophe in each of two flow-map values leaves two entries":
    let r = readMap("author: {name: O'Brien, url: /o'b/}", "author")
    check r.error == ""
    check r.entries == @[pair("name", "O'Brien"), pair("url", "/o'b/")]

  test "a double quote in each of two flow-list items leaves two items":
    let r = readList("sizes: [5\" disk, 3.5\" floppy]", "sizes")
    check r.error == ""
    check r.items == @["5\" disk", "3.5\" floppy"]

  test "a single apostrophe in a flow-list item is text, not the start of a quoted string":
    let r = readList("tags: [it's, nim]", "tags")
    check r.error == ""
    check r.items == @["it's", "nim"]
