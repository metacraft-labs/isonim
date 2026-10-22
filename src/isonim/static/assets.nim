## isonim/static/assets -- the static-asset pipeline: content-hashed file
## names (`style.css` -> `style.<hash>.css`), an `asset-manifest.json`
## mapping each original to its hashed name, and a small CSS purge that
## drops the rules for classes no built page uses.
##
## Moved from isonim-docs (`src/core/asset_pipeline.nim`, plus the
## directory pass `hashAndPurgeAssets` from `src/build_site.nim`), which
## now re-export it. `contentHash` is a cache key, not a security hash.
## The directory pass visits files in sorted order, so the manifest and
## the returned rewrites do not depend on the order the file system lists
## a directory in.

import std/[os, sets, strutils, json, sequtils, algorithm]

{.push warning[Deprecated]: off.}
import std/md5
{.pop.}

proc contentHash*(content: string): string =
  ## Short deterministic content-hash for cache-busting filenames
  ## (`style.<hash>.css`) -- a prefix of the MD5 digest is plenty of
  ## entropy for a build-time cache key; this is not a security hash.
  getMD5(content)[0 ..< 10]

proc hashedAssetName*(relPath, content: string): string =
  ## `style.css` -> `style.<hash>.css`; a nested `relPath` keeps its
  ## directory prefix, e.g. `img/logo.png` -> `img/logo.<hash>.png`.
  let (dir, name, ext) = splitFile(relPath)
  let hashedName = name & "." & contentHash(content) & ext
  if dir.len == 0: hashedName else: dir / hashedName

proc extractUsedClasses*(html: string): HashSet[string] =
  ## Scans `class="..."`/`class='...'` attribute values out of rendered
  ## HTML -- the set `purgeCss` keeps rules for.
  result = initHashSet[string]()
  var i = 0
  while true:
    let idx = html.find("class=", i)
    if idx < 0: break
    var j = idx + "class=".len
    if j < html.len and html[j] in {'"', '\''}:
      let quote = html[j]
      inc j
      let start = j
      while j < html.len and html[j] != quote: inc j
      for token in html[start ..< j].splitWhitespace():
        result.incl token
      i = j + 1
    else:
      i = idx + "class=".len

proc stripComments(css: string): string =
  ## Strips `/* ... */` comments before any brace/selector parsing --
  ## comments are free-form prose and may themselves contain `{`, `}`,
  ## or `.word` tokens (e.g. a file-header comment naming a `.nim`
  ## module), which would otherwise desync the block splitter or be
  ## misread as class selectors.
  result = newStringOfCap(css.len)
  var i = 0
  while i < css.len:
    if css[i] == '/' and i + 1 < css.len and css[i + 1] == '*':
      let closeIdx = css.find("*/", i + 2)
      if closeIdx < 0: break
      i = closeIdx + 2
    else:
      result.add css[i]
      inc i

proc splitTopLevelBlocks(css: string): seq[tuple[header, body: string]] =
  ## Splits `css` into top-level `header { body }` pairs; `body` keeps
  ## any nested braces verbatim (e.g. an `@media` block's own rules),
  ## matched by brace depth rather than assuming one level of nesting.
  ## Assumes comments have already been stripped (see `stripComments`).
  result = @[]
  var i = 0
  let n = css.len
  while i < n:
    let openIdx = css.find('{', i)
    if openIdx < 0: break
    let header = css[i ..< openIdx].strip()
    var depth = 1
    var j = openIdx + 1
    while j < n and depth > 0:
      case css[j]
      of '{': inc depth
      of '}': dec depth
      else: discard
      inc j
    let body = css[openIdx + 1 ..< max(openIdx + 1, j - 1)]
    if header.len > 0:
      result.add (header, body)
    i = j

proc classesInSelector(selector: string): seq[string] =
  result = @[]
  var i = 0
  while i < selector.len:
    if selector[i] == '.':
      var j = i + 1
      while j < selector.len and (selector[j].isAlphaNumeric or selector[j] in {'-', '_'}):
        inc j
      if j > i + 1:
        result.add selector[i + 1 ..< j]
      i = j
    else:
      inc i

proc selectorListIsUsed(headerCombined: string, used: HashSet[string]): bool =
  ## `headerCombined` may be a comma-separated selector list; kept if
  ## ANY individual selector has no class constraint (element/attribute/
  ## pseudo selectors, `:root`, ...) or references a used class.
  for sel in headerCombined.split(','):
    let classes = classesInSelector(sel.strip())
    if classes.len == 0 or classes.anyIt(it in used):
      return true
  false

proc purgeCss*(css: string, usedClasses: HashSet[string]): string =
  ## Drops CSS rules whose selectors reference ONLY unused classes --
  ## a hand-rolled equivalent of a Tailwind purge, run against the
  ## classes actually emitted across every rendered page. Rules with no
  ## class in their selector (resets, `:root`, attribute selectors) and
  ## unrecognized at-rules (`@font-face`, `@keyframes`, ...) are always
  ## kept verbatim; `@media`/`@supports` recurse into their nested rules.
  var parts: seq[string] = @[]
  for (header, body) in splitTopLevelBlocks(stripComments(css)):
    let lower = header.toLowerAscii
    if lower.startsWith("@media") or lower.startsWith("@supports"):
      var nested: seq[string] = @[]
      for (innerHeader, innerBody) in splitTopLevelBlocks(body):
        if selectorListIsUsed(innerHeader, usedClasses):
          nested.add innerHeader & " {" & innerBody & "}"
      if nested.len > 0:
        parts.add header & " {\n" & nested.join("\n") & "\n}"
    elif header.startsWith("@"):
      parts.add header & " {" & body & "}"
    elif selectorListIsUsed(header, usedClasses):
      parts.add header & " {" & body & "}"
  parts.join("\n\n") & "\n"

proc renderAssetManifest*(entries: openArray[tuple[original, hashed: string]]): string =
  ## The `asset-manifest.json` text: one key per original path, in the
  ## order given, pretty-printed with a trailing newline.
  var obj = newJObject()
  for (original, hashed) in entries:
    obj[original] = %hashed
  pretty(obj) & "\n"

proc writeAssetManifest*(path: string, entries: seq[tuple[original, hashed: string]]) =
  ## Writes `renderAssetManifest(entries)` to `path`.
  writeFile(path, renderAssetManifest(entries))

proc hashAndPurgeAssets*(siteDir: string; usedClasses: HashSet[string];
                         purgeFiles: openArray[string] = ["style.css"];
                         assetsSubdir = "assets";
                         manifestName = "asset-manifest.json"):
    seq[tuple[fromHref, toHref: string]] =
  ## Content-hashes every file under `siteDir/assetsSubdir` in place,
  ## first purging (`purgeCss`) each file whose path relative to that
  ## directory is in `purgeFiles`, removes the unhashed copies, and writes
  ## `siteDir/manifestName` (`assets/<name>` -> `assets/<hashed name>`).
  ## Returns the `/assets/<name>` -> `/assets/<hashed name>` rewrites a
  ## caller applies to already-rendered HTML. Files are visited in sorted
  ## path order (with `/` separators on every OS), so equal inputs give an
  ## equal manifest and equal rewrites. A missing assets directory yields
  ## an empty manifest.
  let assetsDir = siteDir / assetsSubdir
  var relPaths: seq[string] = @[]
  if dirExists(assetsDir):
    for relPath in walkDirRec(assetsDir, relative = true):
      relPaths.add relPath.replace('\\', '/')
  relPaths.sort(system.cmp[string])
  # Snapshot and validate the whole plan before any destination can
  # overwrite an original. A hashed name may itself be an input name.
  var planned: seq[tuple[original, hashed, content: string]]
  var destinations = initHashSet[string]()
  for relPath in relPaths:
    var content = readFile(assetsDir / relPath)
    if relPath in purgeFiles: content = purgeCss(content, usedClasses)
    let hashed = hashedAssetName(relPath, content).replace('\\', '/')
    let key = hashed.toLowerAscii
    if key in destinations or dirExists(assetsDir / hashed):
      raise newException(ValueError, "asset destination collision: " & hashed)
    destinations.incl key
    planned.add (relPath, hashed, content)
  var manifestEntries: seq[tuple[original, hashed: string]]
  for item in planned:
    let destination = assetsDir / item.hashed
    createDir(destination.parentDir)
    # A copied symlink is an input, never permission to overwrite its target.
    if symlinkExists(destination): removeFile(destination)
    writeFile(destination, item.content)
    manifestEntries.add (assetsSubdir & "/" & item.original, assetsSubdir & "/" & item.hashed)
    result.add ("/" & assetsSubdir & "/" & item.original, "/" & assetsSubdir & "/" & item.hashed)
  for item in planned:
    if item.original.toLowerAscii notin destinations:
      removeFile(assetsDir / item.original)
  writeAssetManifest(siteDir / manifestName, manifestEntries)
