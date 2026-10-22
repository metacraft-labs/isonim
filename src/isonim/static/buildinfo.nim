## isonim/static/buildinfo -- `build.json`, the record that ties a
## deployed static site to the sources it was built from.
##
## It names the generator, the source revision, the revisions of the
## components that went into the build (the framework, a theme, ...), the
## build time taken from `SOURCE_DATE_EPOCH`
## (https://reproducible-builds.org/specs/source-date-epoch/) rather than
## the wall clock, and a hash of every other file of the output tree. A
## deployed site can then be matched to a commit, and two builds compared
## by one line.
##
## The JSON is written by hand with a fixed key order (no `std/json`
## table), and nothing in it depends on the build machine, so equal inputs
## give equal bytes. Hashing a tree reads files, so `treeHash` and
## `writeBuildInfo` are C-only; `renderBuildJson` is pure.

import std/[strutils, algorithm]
import ./head  # jsonLdString: the same JSON string encoder
import ./csp   # sha256Digest

when not defined(js):
  import std/os

type
  BuildComponent* = object
    ## One input of the build, such as the framework or a theme.
    name*: string
    revision*: string

  SiteBuildInfo* = object
    generator*: string            ## e.g. "isonim-blog 0.1.0"
    sourceRevision*: string       ## The site source's revision (a commit id).
    components*: seq[BuildComponent]
    sourceDateEpoch*: int64       ## Seconds since the Unix epoch; -1 = unknown.
    outputHash*: string           ## "sha256-<hex>" over the output tree (`treeHash`).

const buildInfoFileName* = "build.json"

proc toHex(digest: string): string =
  const hexDigits = "0123456789abcdef"
  for c in digest:
    result.add hexDigits[(ord(c) shr 4) and 0xF]
    result.add hexDigits[ord(c) and 0xF]

proc sha256Hex*(data: string): string =
  ## Lower-case hex SHA-256 of `data`.
  toHex(sha256Digest(data))

proc checksumLine(path, content: string): string =
  ## GNU sha256sum's default (untagged, text-mode) filename encoding. A
  ## leading backslash marks a line whose filename contains escapes;
  ## newline, carriage return and backslash become \n, \r and \\.
  ## Thus a filename cannot inject another record into the tree listing.
  ## https://www.gnu.org/software/coreutils/manual/html_node/cksum-output-modes.html
  let escaped = path.contains({'\n', '\r', '\\'})
  if escaped: result.add '\\'
  result.add sha256Hex(content) & "  "
  for c in path:
    case c
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\\': result.add "\\\\"
    else: result.add c
  result.add '\n'

proc treeHashOf*(files: openArray[tuple[path, content: string]]): string =
  ## "sha256-<hex>" over a set of files: the SHA-256 of one line per file,
  ## `<sha256 of content>  <path>\n` (the `sha256sum` format, with its
  ## filename escaping and leading escape marker), sorted by the original
  ## path bytes. Independent of the order the files are given in.
  var ordered = @files
  ordered.sort(proc(a, b: tuple[path, content: string]): int = cmp(a.path, b.path))
  var lines: seq[string]
  for f in ordered:
    lines.add checksumLine(f.path, f.content)
  "sha256-" & sha256Hex(lines.join(""))

when not defined(js):
  proc treeHash*(dir: string; exclude: openArray[string] = [buildInfoFileName]): string =
    ## `treeHashOf` every file under `dir` (paths relative to it, with `/`
    ## separators), leaving out the relative paths in `exclude` -- by
    ## default `build.json` itself, which records the hash.
    var files: seq[tuple[path, content: string]]
    for rel in walkDirRec(dir, relative = true):
      when defined(windows):
        let p = rel.replace('\\', '/')
      else:
        let p = rel # A POSIX backslash is a filename byte, not a separator.
      if p in exclude: continue
      files.add (p, readFile(dir / rel))
    treeHashOf(files)

  proc sourceDateEpochFromEnv*(): int64 =
    ## `SOURCE_DATE_EPOCH` as an integer, or -1 when it is unset. A value
    ## that is not a non-negative integer is an error, as the specification
    ## requires (a build must not silently fall back to the wall clock).
    let raw = getEnv("SOURCE_DATE_EPOCH")
    if raw.len == 0: return -1
    for c in raw:
      if c notin {'0'..'9'}:
        raise newException(ValueError,
          "SOURCE_DATE_EPOCH must be a non-negative integer, got '" & raw & "'")
    parseBiggestInt(raw).int64

proc renderBuildJson*(info: SiteBuildInfo): string =
  ## The `build.json` text: keys in a fixed order, components sorted by
  ## name, two-space indentation, a trailing newline.
  var comps = info.components
  comps.sort(proc(a, b: BuildComponent): int = cmp(a.name, b.name))
  result = "{\n"
  result.add "  \"generator\": " & jsonLdString(info.generator) & ",\n"
  result.add "  \"sourceRevision\": " & jsonLdString(info.sourceRevision) & ",\n"
  result.add "  \"components\": ["
  for i, c in comps:
    result.add (if i == 0: "\n" else: ",\n")
    result.add "    {\"name\": " & jsonLdString(c.name) & ", \"revision\": " &
      jsonLdString(c.revision) & "}"
  result.add (if comps.len > 0: "\n  ],\n" else: "],\n")
  result.add "  \"sourceDateEpoch\": " &
    (if info.sourceDateEpoch < 0: "null" else: $info.sourceDateEpoch) & ",\n"
  result.add "  \"outputHash\": " & jsonLdString(info.outputHash) & "\n"
  result.add "}\n"

when not defined(js):
  proc writeBuildInfo*(outDir: string; info: SiteBuildInfo): SiteBuildInfo =
    ## Hashes `outDir` (without `build.json`), records the hash in a copy of
    ## `info`, writes `outDir/build.json` and returns the record written.
    result = info
    result.outputHash = treeHash(outDir)
    writeFile(outDir / buildInfoFileName, renderBuildJson(result))
