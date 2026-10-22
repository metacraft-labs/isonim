## isonim/static/exporter -- writes a static site: a set of rendered
## pages and files to an output directory, with clean URLs, in a
## deterministic order, and without ever leaving a half-written site.
##
## (The module is `exporter`, not `export`: `export` is a Nim keyword, so
## `import isonim/static/export` would not parse.)
##
## - **Clean URLs.** A page's route maps to `<route>/index.html`
##   (`/` -> `index.html`, `/guide/dsl` and `/guide/dsl/` ->
##   `guide/dsl/index.html`). A route ending in `.html` (`/404.html`) is
##   written as that file. Anything else a site publishes (feeds, assets,
##   `robots.txt`) is a `SiteFile` with its own path.
## - **Deterministic order.** Pages are ordered by route and files by path
##   (byte-wise), whatever order they are given in. The order is the one
##   the report lists, and the one `sitemapEntriesFor` gives the sitemap,
##   so equal inputs give byte-identical output trees.
## - **Collisions are errors.** Two pages that map to the same file, a
##   file that shadows a page, and a path that escapes the output
##   directory (`..`, an absolute path) raise `ExportError` before
##   anything is written.
## - **Atomic output.** An owned, unique staging directory on the same
##   filesystem is published by a single directory exchange (Linux/macOS).
##   Readers always resolve either a complete old tree or a complete new
##   tree. Separate reads can straddle a publication. Unsupported
##   platforms/filesystems fail without moving the existing output.
##
## C-only (it writes files). Moved from the export loops of isonim-docs
## (`src/build_site.nim`: `outputPathFor`, the page-writing loop) and
## isonim.com's `src/static_export.nim` (`exportRoute`).

when defined(js):
  {.error: "isonim/static/exporter writes files; it is not for the JS target".}

import std/[os, strutils, algorithm, sets, tempfiles]
import ./sitemap

type
  SitePage* = object
    ## One rendered page.
    route*: string   ## The URL path: `/`, `/posts/hello`, `/404.html`.
    html*: string    ## The complete document.
    lastmod*: string ## The sitemap's `<lastmod>` (W3C Datetime); "" omits it.
    noindex*: bool   ## Leave the page out of the sitemap (drafts, error pages).

  SiteFile* = object
    ## One file published as is.
    path*: string    ## Relative to the site root, `/`-separated (`robots.txt`,
                     ## `assets/style.3f2a.css`, `feed.xml`).
    content*: string

  ExportedPage* = object
    route*: string
    relPath*: string ## Where the page was written, relative to `outDir`.
    lastmod*: string
    noindex*: bool

  ExportReport* = object
    outDir*: string
    pages*: seq[ExportedPage] ## In route order.
    files*: seq[string]       ## Every path written (pages and files), sorted.

  StagingArea* = ref object
    ## A unique resource returned by beginStaging. Only this handle can
    ## publish or discard it; closed handles cannot remove a later tree.
    directory: string
    target: string
    closed: bool

  ExportError* = object of CatchableError
    ## An invalid or colliding route or path; nothing was written.

type ExportCleanupError* = object of CatchableError
  ## Publication succeeded, but releasing the obsolete tree failed.
  ## Distinct from a publication error: the new output is already live.
  publishedDirectory*, obsoleteDirectory*: string

const
  stagingSuffix* = ".isonim-staging"
  previousSuffix* = ".isonim-previous"

proc fail(msg: string) {.noreturn.} =
  raise newException(ExportError, "exportSite: " & msg)

proc checkRelPath(what, p: string) =
  ## A relative, `/`-separated path that stays inside the site root.
  if p.len == 0: fail(what & " is empty")
  if p[0] == '/' or '\\' in p or '\0' in p or (p.len > 1 and p[1] == ':'):
    fail(what & " must be a relative path with '/' separators: '" & p & "'")
  for seg in p.split('/'):
    if seg.len == 0 or seg == "." or seg == "..":
      fail(what & " has an empty, '.' or '..' segment: '" & p & "'")

proc outputRelPath*(route: string): string =
  ## Where a page with `route` is written, relative to the output root:
  ## `index.html` for `/`, `<route>/index.html` for a clean URL, the route
  ## itself for one ending in `.html`. Raises `ExportError` for a route
  ## that is not an absolute path or would escape the output directory, or
  ## carries a query or fragment.
  if route.len == 0 or route[0] != '/':
    fail("a route must start with '/': '" & route & "'")
  if '?' in route or '#' in route:
    fail("a route has no query or fragment: '" & route & "'")
  if route == "/": return "index.html"
  var trimmed = route[1 .. ^1]
  if trimmed.endsWith("/"): trimmed.setLen(trimmed.len - 1)
  checkRelPath("route " & route, trimmed)
  if route.toLowerAscii.endsWith(".html"): trimmed
  else: trimmed & "/index.html"

proc orderPages(pages: openArray[SitePage]): seq[SitePage] =
  ## The one place the export order is decided: by route, byte-wise.
  result = @pages
  result.sort(proc(a, b: SitePage): int = cmp(a.route, b.route))

proc orderFiles(files: openArray[SiteFile]): seq[SiteFile] =
  result = @files
  result.sort(proc(a, b: SiteFile): int = cmp(a.path, b.path))

proc planExport(pages: openArray[SitePage]; files: openArray[SiteFile]):
    tuple[pages: seq[(ExportedPage, string)], files: seq[SiteFile]] =
  ## Validates every route and path and checks for collisions, before
  ## anything touches the disk.
  var taken = initHashSet[string]()
  var dirs = initHashSet[string]() # every directory a written file needs
  proc claim(rel, what: string) =
    let key = rel.toLowerAscii # case-insensitive file systems collide too
    if key in taken: fail(what & " collides with another output at '" & rel & "'")
    taken.incl key
    var d = rel
    while true:
      let slash = d.rfind('/')
      if slash < 0: break
      d = d[0 ..< slash]
      dirs.incl d.toLowerAscii
  for p in orderPages(pages):
    let rel = outputRelPath(p.route)
    claim(rel, "route " & p.route)
    result.pages.add (ExportedPage(route: p.route, relPath: rel, lastmod: p.lastmod,
                                   noindex: p.noindex), p.html)
  for f in orderFiles(files):
    checkRelPath("file path", f.path)
    claim(f.path, "file " & f.path)
    result.files.add f
  for key in taken:
    if key in dirs: fail("'" & key & "' is both a file and a directory")

when defined(linux) or defined(macosx):
  # Do not fall back to two renames: that removes the public directory
  # between syscalls. NOREPLACE/EXCL also handles two first-time publishers.
  {.emit: """
#include <errno.h>
#include <stdio.h>
#if defined(__linux__)
#include <unistd.h>
#include <sys/syscall.h>
#endif
static int isonim_publish_directory(const char *stage, const char *target) {
#if defined(__linux__)
  if (syscall(SYS_renameat2, -100, stage, -100, target, 2) == 0) return 0;
  if (errno != ENOENT) return errno;
  if (syscall(SYS_renameat2, -100, stage, -100, target, 1) == 0) return 0;
  if (errno != EEXIST) return errno;
  if (syscall(SYS_renameat2, -100, stage, -100, target, 2) == 0) return 0;
#else
  if (renamex_np(stage, target, RENAME_SWAP) == 0) return 0;
  if (errno != ENOENT) return errno;
  if (renamex_np(stage, target, RENAME_EXCL) == 0) return 0;
  if (errno != EEXIST) return errno;
  if (renamex_np(stage, target, RENAME_SWAP) == 0) return 0;
#endif
  return errno;
}
""".}
  proc publishDirectory(stage, target: cstring): cint
    {.importc: "isonim_publish_directory", nodecl.}

proc path*(stage: StagingArea): string =
  ## The writable directory belonging to an open staging area.
  if stage.isNil or stage.closed: fail("staging area is closed")
  stage.directory

proc beginStaging*(outDir: string): StagingArea =
  ## Reserve a unique sibling directory. Stale or concurrent staging
  ## resources are never reused or removed.
  let target = normalizedPath(absolutePath(outDir))
  if target.parentDir.len == 0 or target.parentDir == target: fail("the filesystem root cannot be exported")
  if symlinkExists(target) or fileExists(target):
    fail("output must be a directory, not a symlink or file: " & target)
  createDir(target.parentDir)
  StagingArea(directory: createTempDir(extractFilename(target) & stagingSuffix & "-",
                                       "", target.parentDir), target: target)

proc removeTreeNoFollow(dir: string) =
  ## In particular a symlink at the root must be unlinked, not walked.
  ## walkDir distinguishes nested links, including links to directories.
  if symlinkExists(dir):
    removeFile(dir)
  elif dirExists(dir):
    for kind, child in walkDir(dir):
      if kind == pcDir: removeTreeNoFollow(child)
      else: removeFile(child)
    removeDir(dir)

proc discardStaging*(stage: StagingArea) =
  ## Release this handle's resource only. Safe after a successful commit.
  if stage.isNil or stage.closed: return
  removeTreeNoFollow(stage.directory)
  stage.closed = true

proc commitStaging*(stage: StagingArea; outDir: string) =
  ## Atomically publish a completed tree. On a publication error neither
  ## tree is moved. After an exchange the old output occupies our unique
  ## staging path and is removed without following symlinks.
  let source = stage.path
  let target = normalizedPath(absolutePath(outDir))
  if target != stage.target: fail("staging area belongs to a different output")
  if symlinkExists(source) or not dirExists(source): fail("staging directory was replaced")
  if symlinkExists(target) or fileExists(target): fail("output is not a directory")
  when defined(linux) or defined(macosx):
    let error = publishDirectory(source.cstring, target.cstring)
    if error != 0: raiseOSError(OSErrorCode(error), "atomic site publication")
    stage.closed = true
    try:
      removeTreeNoFollow(source)
    except CatchableError as cause:
      var error = newException(ExportCleanupError,
        "site published at " & target & "; obsolete output cleanup failed at " & source & ": " & cause.msg)
      error.publishedDirectory = target
      error.obsoleteDirectory = source
      raise error
  else:
    fail("atomic directory publication requires Linux or macOS")

proc writeSiteTree*(dir: string; pages: openArray[SitePage];
                    files: openArray[SiteFile] = []): ExportReport =
  ## Writes `pages` and `files` into `dir` (normally a staging directory),
  ## in route then path order, and returns what was written. Validates
  ## and checks for collisions first, so on `ExportError` nothing is
  ## written. Does not empty `dir`: files already there (a compiled
  ## bundle, say) stay, and are overwritten by a page or file of the same
  ## path.
  let plan = planExport(pages, files)
  result.outDir = dir
  for (page, html) in plan.pages:
    let abs = dir / page.relPath
    createDir(abs.parentDir)
    writeFile(abs, html)
    result.pages.add page
    result.files.add page.relPath
  for f in plan.files:
    let abs = dir / f.path
    createDir(abs.parentDir)
    writeFile(abs, f.content)
    result.files.add f.path
  result.files.sort(system.cmp[string])

proc exportSite*(pages: openArray[SitePage]; outDir: string;
                 files: openArray[SiteFile] = []): ExportReport =
  ## Exports a static site: `pages` (clean URLs) and `files` to `outDir`,
  ## replacing whatever was there, atomically (see the module notes).
  ## Raises `ExportError` for an invalid or colliding route or path, and
  ## `OSError`/`IOError` for a failed write or publication; in those cases
  ## `outDir` is left as it was. `ExportCleanupError` instead means the new
  ## site is live but removal of the obsolete tree needs attention.
  let stage = beginStaging(outDir)
  try:
    result = writeSiteTree(stage.path, pages, files)
    commitStaging(stage, outDir)
  except CatchableError:
    discardStaging(stage)
    raise
  result.outDir = outDir

proc readTreeFiles*(srcDir: string; prefix = ""): seq[SiteFile] =
  ## Every file under `srcDir` as a `SiteFile` whose path is `prefix`
  ## joined with its path relative to `srcDir` (`/`-separated), sorted by
  ## path. For copying a directory of static files into an export. A
  ## missing `srcDir` gives an empty list.
  if not dirExists(srcDir): return
  for rel in walkDirRec(srcDir, relative = true):
    let p = rel.replace('\\', '/')
    let path = if prefix.len == 0: p else: prefix.strip(chars = {'/'}) & "/" & p
    result.add SiteFile(path: path, content: readFile(srcDir / rel))
  result.sort(proc(a, b: SiteFile): int = cmp(a.path, b.path))

proc sitemapEntriesFor*(report: ExportReport; baseUrl: string): seq[SitemapEntry] =
  ## The sitemap entries for the exported pages that are not `noindex`, in
  ## the report's route order, with their `lastmod`.
  for p in report.pages:
    if not p.noindex:
      result.add sitemapEntry(baseUrl, p.route, p.lastmod)

proc sitemapEntriesFor*(pages: openArray[SitePage]; baseUrl: string): seq[SitemapEntry] =
  ## The same, before export: the pages in export order, without the
  ## `noindex` ones. Lets a generator put `sitemap.xml` among the files of
  ## the one `exportSite` call.
  for p in orderPages(pages):
    if not p.noindex:
      result.add sitemapEntry(baseUrl, p.route, p.lastmod)
