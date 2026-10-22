## isonim/content/anchors -- stable heading anchor IDs.
##
## Stable rules so tables of contents, deep links and reference
## resolution don't churn: a heading's ID is a lowercase,
## punctuation-free slug of its own text, deduped within one document by
## a numeric suffix on repeat ("-2", "-3", ...) regardless of heading
## level or nesting. IDs are flat URL fragments, not scoped per section,
## so dedup has to be document-wide.
##
## Pure string and table work with no filesystem access, so it behaves
## identically on `nim c` and `nim js`. Moved here unchanged from
## isonim-docs (`src/core/anchors.nim`, which now re-exports this
## module) so every IsoNim content consumer shares one slug rule.

import std/[strutils, tables, sets]

proc slugifyHeadingText*(text: string): string =
  ## Lowercases `text` and collapses every run of non `[a-z0-9]`
  ## characters (punctuation, whitespace, symbols) into a single hyphen,
  ## trimming any leading/trailing hyphen -- stable across punctuation
  ## differences ("Getting Started!" and "Getting, Started" both slugify
  ## to "getting-started").
  var lastWasHyphen = true ## suppresses a leading hyphen
  for ch in text.toLowerAscii():
    if ch in {'a'..'z', '0'..'9'}:
      result.add ch
      lastWasHyphen = false
    elif not lastWasHyphen:
      result.add '-'
      lastWasHyphen = true
  while result.len > 0 and result[^1] == '-':
    result.setLen(result.len - 1)

type
  AnchorIdRegistry* = object
    ## Tracks how many times each base slug has been seen so far in one
    ## document, so repeated headings get deduped suffixes in document
    ## order.
    counts: Table[string, int]
    used: HashSet[string]

proc newAnchorIdRegistry*(): AnchorIdRegistry =
  AnchorIdRegistry(counts: initTable[string, int]())

proc uniqueId(reg: var AnchorIdRegistry; base: string): string =
  var seen = reg.counts.getOrDefault(base, 0) + 1
  result = if seen == 1: base else: base & "-" & $seen
  # An authored suffix can collide with an earlier generated one (A, A,
  # A-2). Track emitted IDs as well as counts, across all anchor kinds.
  while result in reg.used:
    inc seen
    result = base & "-" & $seen
  reg.counts[base] = seen
  reg.used.incl result

proc nextId*(reg: var AnchorIdRegistry; headingText: string): string =
  ## Assigns the next stable anchor ID for `headingText`: the first
  ## occurrence of a base slug gets the bare slug, every later duplicate
  ## gets a "-2", "-3", ... suffix. A heading that slugifies to an empty
  ## string (e.g. a heading made entirely of punctuation) falls back to
  ## the literal base "section" so every heading still gets a usable,
  ## non-empty ID.
  let slug = slugifyHeadingText(headingText)
  let base = if slug.len > 0: slug else: "section"
  reg.uniqueId(base)

proc nextRawId*(reg: var AnchorIdRegistry; base: string): string =
  ## Like `nextId`, but dedups on an ALREADY-FORMED `base` WITHOUT
  ## slugifying it -- for code-symbol anchors (M8 deliverable 2) whose
  ## identifiers are case-sensitive and may carry `.`/`_` that must be
  ## preserved verbatim in the fragment (e.g. `sym-MyType.myProc`, not the
  ## lossy `sym-mytype-myproc` `slugifyHeadingText` would produce). Reuses
  ## the exact same shared `AnchorIdRegistry` dedup counter markdown
  ## headings and OpenAPI operation anchors use, so a symbol anchor dedups
  ## in the same document-order, "-2"/"-3"-suffixed way -- only the base
  ## formation differs. An empty base falls back to the literal "sym".
  let b = if base.len > 0: base else: "sym"
  reg.uniqueId(b)

proc assignHeadingIds*(headingTexts: seq[string]): seq[string] =
  ## Batch convenience form: assigns IDs for an ordered seq of heading
  ## texts within one fresh document, in order.
  var reg = newAnchorIdRegistry()
  for text in headingTexts:
    result.add reg.nextId(text)
