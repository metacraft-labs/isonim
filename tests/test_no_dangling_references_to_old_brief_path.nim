## REV-M10 — guard test: no code/doc reference to the legacy brief
## tree path remains in the active surface.
##
## The legacy tree was deleted in REV-M10; any source/doc/Justfile that
## still names the old path is a dangling reference that would mislead
## a future agent.  The scan covers both ``isonim-examples`` (the
## original home of the briefs) and ``isonim`` (which previously
## cross-referenced them from CLI docs / tests).
##
## codetracer-specs is *not* scanned — that repo intentionally retains
## historical references to document the migration itself.
##
## NOTE: the forbidden needle is assembled at runtime from two halves
## so this test file does not itself contain the literal needle (which
## would cause it to flag itself).

import std/[unittest, os, strutils]

const RepoRoots = [
  currentSourcePath().parentDir().parentDir().parentDir() / "isonim-examples",
  currentSourcePath().parentDir().parentDir().parentDir() / "isonim",
]

# Assembled at runtime so the literal substring is not present in
# this source file.
const ForbiddenNeedleA = "tools/visual-review"
const ForbiddenNeedleB = "-briefs"
let ForbiddenNeedle = ForbiddenNeedleA & ForbiddenNeedleB

# Directories we deliberately skip during the scan: build artifacts,
# generated bundles, dependency caches.  Anything outside these is
# fair game.
const SkipDirs = [
  "build",
  "node_modules",
  ".git",
  "nimcache",
  "dist",
  "test-logs",
  "bench-results",
  ".direnv",
  "vendor",
  "screenshots",
]

proc shouldSkip(path: string): bool =
  let tail = splitPath(path).tail
  for s in SkipDirs:
    if tail == s: return true
  return false

proc isLikelyBinary(path: string): bool =
  ## Skip compiled test binaries and other obvious non-text files.
  ## We use a heuristic: extensionless executables in the tests/ tree
  ## are nim-compiled test artifacts (e.g.
  ## ``tests/test_no_dangling_references_to_old_brief_path``) which
  ## embed string constants from this very file.
  let (_, name, ext) = splitFile(path)
  if ext == "": return true   # extensionless => likely a binary
  let binExts = [".o", ".obj", ".a", ".so", ".dylib", ".dll",
                 ".png", ".jpg", ".jpeg", ".gif", ".webp",
                 ".pdf", ".zip", ".gz", ".tgz", ".bz2",
                 ".woff", ".woff2", ".ttf", ".otf",
                 ".exe", ".bin"]
  if ext.toLowerAscii in binExts: return true
  discard name
  return false

iterator scanFiles(root: string): string =
  ## Recursive file walker that skips noisy directories.
  var stack = @[root]
  while stack.len > 0:
    let dir = stack.pop()
    for kind, path in walkDir(dir):
      case kind
      of pcDir, pcLinkToDir:
        if shouldSkip(path): continue
        stack.add(path)
      of pcFile, pcLinkToFile:
        if isLikelyBinary(path): continue
        yield path

suite "REV-M10 dangling-reference scan":
  test "test_no_dangling_references_to_old_brief_path":
    var offenders: seq[string] = @[]
    for root in RepoRoots:
      if not dirExists(root): continue
      for path in scanFiles(root):
        # Read in binary-safe mode — many files are markdown/source but
        # we don't want to choke on the occasional binary asset.
        var data = ""
        try:
          data = readFile(path)
        except IOError, OSError:
          continue
        if ForbiddenNeedle in data:
          offenders.add(path)

    if offenders.len > 0:
      echo "REV-M10: dangling references to legacy brief path '",
           ForbiddenNeedle, "':"
      for o in offenders:
        echo "  ", o
    check offenders.len == 0
