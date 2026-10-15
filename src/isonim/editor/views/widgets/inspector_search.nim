## Inspector section search — row registration.
##
## Editor spec "Section catalogue": "A search field at the top of the
## inspector (⌘F focus) filters sections by name and properties by label —
## sections without matches collapse; sections with matches open and
## highlight the matched rows."
##
## Matching a property LABEL needs to know which rows a section shows, and
## that is decided by each section widget (Typography only for text, the
## per-corner rows only when toggled, rows rebuilt on selection ...). Rather
## than keep a second, drifting catalogue of row labels next to the widgets,
## every row registers its own searchable text with the section it was
## mounted in. The section frame provides an `InspectorSectionSearch` through
## the reactive owner tree (`isonim/core/context`); a row mounted anywhere
## below it -- including inside a section's own render effects -- finds it
## with `useContext`, registers while it is mounted and unregisters on
## cleanup. A row mounted outside an inspector section (widget tests, the
## variable editor) finds no provider and does nothing.

import std/strutils

import isonim/core/signals
import isonim/core/owner
import isonim/core/batch
import isonim/core/context

when defined(js):
  import std/dom
  import isonim/web/dom_api

  proc readInspectorSearchKey[E: dom.Event | dom_api.Event](ev: E): cstring
    {.importjs: "(#.key || '')".}

  proc inspectorSearchKey*(ev: dom.Event | dom_api.Event): string =
    ## The key of a keyboard event; a plain Event has none.
    $readInspectorSearchKey(ev)

proc inspectorSearchKey*[E](ev: E): string =
  ev.key

type
  InspectorSectionSearch* = ref object
    query*: proc(): string
      ## The active query, already stripped and lower-cased. Reactive: read
      ## it inside an effect to follow the search field.
    labels*: Signal[seq[string]]
      ## Searchable text of every row currently mounted in the section,
      ## lower-cased. One entry per mounted row.

let inspectorSectionSearchContext* =
  createContext[InspectorSectionSearch](nil)

func normalizedSearchQuery*(raw: string): string =
  raw.strip().toLowerAscii()

func searchTextMatches*(text, query: string): bool =
  ## `query` must already be normalized. An empty query matches nothing:
  ## "no search" is not "everything is a match", or every row would be
  ## highlighted whenever the field is empty.
  query.len > 0 and text.toLowerAscii().contains(query)

proc createInspectorSectionSearch*(query: proc(): string): InspectorSectionSearch =
  InspectorSectionSearch(query: query,
    labels: createSignal[seq[string]](@[]))

proc registerInspectorSearchText*(text: string): InspectorSectionSearch =
  ## Register `text` with the enclosing section, if any, for as long as the
  ## current owner lives. Returns the section search (nil outside a section)
  ## so the caller can follow the query for its own highlight.
  result = useContext(inspectorSectionSearchContext)
  if result == nil: return
  let search = result
  let entry = text.toLowerAscii()
  untrack(proc() =
    var next = search.labels.val
    next.add entry
    search.labels.val = next)
  onCleanup(proc() =
    untrack(proc() =
      var next = search.labels.val
      let at = next.find(entry)
      if at >= 0:
        next.delete(at)
        search.labels.val = next))

proc sectionRowsMatch*(search: InspectorSectionSearch; query: string): bool =
  ## True when any mounted row of the section matches `query`. Reads
  ## `labels`, so an effect calling this follows rows being (re)mounted.
  if search == nil or query.len == 0: return false
  for text in search.labels.val:
    if searchTextMatches(text, query): return true
  false
