## isonim/ssr/renderer.nim
##
## Server-side rendering: renderToString and SSR element helpers.
## Generates HTML strings from the reactive component tree without a DOM.
##
## Port of dom-expressions server rendering.

import isonim/core/owner
import isonim/ssr/escape
import isonim/ssr/markers

proc renderToString*(fn: proc(): string): string =
  ## Synchronous SSR. Creates a reactive root, runs the component,
  ## collects the HTML string output.
  resetHydrationCounter()
  var html = ""
  createRoot proc(dispose: proc()) =
    html = fn()
    dispose()
  result = html

const voidElements = [
  "area", "base", "br", "col", "embed", "hr", "img",
  "input", "keygen", "link", "menuitem", "meta", "param",
  "source", "track", "wbr",
]

proc ssrElement*(tag: string; attrs: openArray[(string, string)] = [];
    children: string = ""; needsId: bool = false): string =
  ## Renders an HTML element as a string.
  result = "<" & tag
  if needsId:
    result.add ssrHydrationKey()
  for (key, val) in attrs:
    result.add " " & escapeHtml(key) & "=\"" & escapeAttr(val) & "\""
  if tag in voidElements:
    result.add " />"
  else:
    result.add ">" & children & "</" & tag & ">"

proc ssrAttribute*(key: string; value: string; isBoolean: bool = false): string =
  ## Renders a single HTML attribute as a string.
  if isBoolean:
    if value.len > 0 and value != "false": " " & key else: ""
  elif value.len > 0:
    " " & key & "=\"" & escapeAttr(value) & "\""
  else: ""

proc ssrStyle*(styles: openArray[(string, string)]): string =
  ## Renders inline styles as a semicolon-separated string.
  for i, (key, val) in styles:
    if i > 0: result.add ";"
    result.add key & ":" & escapeAttr(val)

proc ssrClassList*(classes: openArray[(string, bool)]): string =
  ## Renders a class list from name/active pairs.
  var first = true
  for (name, active) in classes:
    if active:
      if not first: result.add " "
      result.add escapeHtml(name)
      first = false

proc ssrFor*[T](items: seq[T]; body: proc(item: T, index: int): string): string =
  ## SSR For: renders each item to string, concatenates.
  for i, item in items:
    result.add body(item, i)

proc ssrShow*(condition: bool; body: proc(): string;
              fallback: proc(): string = nil): string =
  ## SSR Show: renders body or fallback as string based on condition.
  if condition:
    result = body()
  elif fallback != nil:
    result = fallback()
