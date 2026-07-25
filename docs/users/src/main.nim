## ../isonim/docs/users -- thin JS mount entry (M1 corrective deliverable 4).
##
## Mirrors isonim-docs' own `src/main_web.nim` structure -- route
## resolution and `buildShellViewModel`/`renderSiteFrame`/
## `renderMarkdownPage` are 100% shared with the framework via the
## imports below -- but embeds THIS site's own `content/` dir at compile
## time and passes NO explicit manifest to `createRouteApp`, so the
## framework's own auto-discovery default (`buildManifestFromEntries` fed
## from the compile-time embed, M1 corrective deliverables 1+2) resolves
## every real IsoNim route end to end, exactly like `ssr.nim`/`build.nim`
## do on the C target.

when not defined(js):
  {.error: "main.nim requires the JS backend: nim js -r/nim js main.nim".}

import std/[os, tables]
import isonim/web/dom_api
import isonim/web/client
import isonim/web/web_renderer
import core/content
import core/content_embed
import core/config
import core/routes
import core/shell_vm
import core/markdown_vm
import core/navigation_vm
import core/references
import core/search_vm
import components/shell
import components/markdown_page
import components/search_view
import ./docs_config

const embeddedContent = embedContentDir(currentSourcePath().parentDir() / "../content")
  ## Every `.md` file under this site's own `content/` dir, embedded at
  ## compile time (there's no real filesystem in the browser) via the
  ## framework's generic `content_embed.embedContentDir` macro.

proc loadEmbeddedPage(contentPath: string): DocsPage =
  parseDocsPage(embeddedContent[contentPath], "content/" & contentPath)

proc loadEmbeddedContentEntry(contentPath: string): ContentEntry =
  parseContentEntry(embeddedContent[contentPath], contentPath)

proc defaultEmbeddedManifest(): RouteManifest =
  ## This site's own framework-default manifest: the JS-target
  ## counterpart to `ssr.nim`/`build.nim`'s `buildManifestFromContent`,
  ## fed from the compile-time `embeddedContent` table instead of a
  ## runtime directory walk.
  var entries: seq[ContentEntry] = @[]
  for contentPath, raw in embeddedContent:
    let entry = parseContentEntry(raw, contentPath)
    if not entry.front.draft:
      entries.add entry
  sortContentEntries(entries)
  buildManifestFromEntries(entries)

proc mountedRoutePage*(contentPath: string): DocsPage =
  ## Exposed for tests.
  loadEmbeddedPage(contentPath)

proc mountedMarkdownPage*(contentPath: string): tuple[title: string, blocks: seq[Block]] =
  ## Exposed for tests.
  let entry = loadEmbeddedContentEntry(contentPath)
  (entry.page.title, parseMarkdownBlocks(entry.page.body, entry.source.path))

# --- live client search (mirrors main_web.nim's own glue) ----------------
proc getInputValue(e: Element): cstring {.importcpp: "#.value".}
proc eventKey(e: Event): cstring {.importcpp: "#.key".}
proc navigateTo(path: cstring) {.importcpp:
  "(typeof window !== 'undefined' && window.location) && (window.location.href = #)".}

proc wireSearchInteractivity(r: WebRenderer; frame: Node; index: SearchIndex) =
  let headerNode = frame.firstChild
  if headerNode.isNodeNil: return
  let titleNode = headerNode.firstChild
  if titleNode.isNodeNil: return
  let searchBoxNode = titleNode.nextSibling
  if searchBoxNode.isNodeNil: return
  let inputNode = searchBoxNode.firstChild
  if inputNode.isNodeNil: return
  let resultsWrapperNode = inputNode.nextSibling
  if resultsWrapperNode.isNodeNil: return
  let resultsWrapperEl = Element(resultsWrapperNode)
  let inputEl = Element(inputNode)

  var vm = newSearchViewModel()

  proc rerenderResults() =
    r.clearChildren(resultsWrapperEl)
    r.appendChild(resultsWrapperEl, renderSearchResultsContent[WebRenderer, Node](r, vm))

  proc onInput(ev: Event) =
    vm = setQuery(vm, index, $getInputValue(inputEl))
    rerenderResults()

  proc onKeydown(ev: Event) =
    case $eventKey(ev)
    of "ArrowDown":
      vm = moveCursor(vm, 1)
      rerenderResults()
    of "ArrowUp":
      vm = moveCursor(vm, -1)
      rerenderResults()
    of "Enter":
      let selected = selectedResult(vm)
      if selected.routePath.len > 0:
        navigateTo(cstring(selected.routePath))
    else:
      discard

  r.addEventListener(inputEl, "input", onInput)
  r.addEventListener(inputEl, "keydown", onKeydown)

proc createRouteApp*(path: string; manifest: RouteManifest = defaultEmbeddedManifest();
                      cfg: DocsConfig = isonimDocsConfig()): Node =
  let aliasEntries = buildAliasRouteEntries(manifest, loadEmbeddedContentEntry)
  let entry = matchRoute(withAliasRedirects(manifest, aliasEntries), path).entry
  let r = WebRenderer()
  if entry.pageKind == pkMarkdown:
    let contentEntry = loadEmbeddedContentEntry(entry.meta.contentPath)
    let doc = parseMarkdownDoc(contentEntry.page.body, contentEntry.source.path,
                                makeContentPathResolver(manifest))
    let title = if contentEntry.page.title.len > 0: contentEntry.page.title else: entry.meta.title
    let navPages = buildNavPages(manifest, loadEmbeddedContentEntry)
    let navigation = buildNavigationViewModel(navPages, entry.canonicalPath, doc.headingTree)
    result = renderMarkdownPage[WebRenderer, Node](r, title, doc.blocks, navigation)
  else:
    let navigation =
      if entry.status == rsNotFound or entry.status == rsRedirect: NavigationViewModel()
      else: buildNavigationViewModel(buildNavPages(manifest, loadEmbeddedContentEntry), entry.canonicalPath)
    let vm = buildShellViewModel(entry, cfg, loadEmbeddedPage, navigation)
    result = renderSiteFrame[WebRenderer, Node](r, vm)
  wireSearchInteractivity(r, result, buildSearchIndex(manifest, loadEmbeddedContentEntry))

when isMainModule:
  let rootEl = document.getElementById("root")
  discard render(proc(): Node = createRouteApp("/"), rootEl)
