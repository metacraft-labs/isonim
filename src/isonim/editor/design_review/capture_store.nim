## REV-M5 — content-addressed PNG capture store.
##
## ``put`` writes a PNG buffer to ``<rootDir>/<sha[0:2]>/<sha>.png``.
## The write is atomic (tmp file + rename) and idempotent (a repeat
## ``put`` of identical bytes returns the existing path and does
## not rewrite the file).
##
## The hash is the lowercase-hex sha256 of the input bytes — same
## digest format the DB's ``captures.png_sha256`` column records
## and the same ``shasum -a 256`` shell-out the rest of the
## design-review code uses.
##
## Fault-tolerance contract verified by
## ``test_capture_store_atomic_write``:
##
##   * A partial write that crashes mid-``put`` leaves at most a
##     ``<sha>.png.tmp`` at the destination; the canonical
##     ``<sha>.png`` is *never* visible unless the file is complete.
##
##   * Restarting after a crash, the next ``put`` with the same
##     bytes happily finishes the write (idempotency).

import std/[os, osproc, streams, strutils]

type
  CaptureStore* = ref object
    rootDir*: string

  CaptureStoreError* = object of CatchableError

proc newCaptureStore*(rootDir: string): CaptureStore =
  ## Create a fresh store handle.  Ensures ``rootDir`` exists.
  if rootDir.len == 0:
    raise newException(CaptureStoreError,
      "newCaptureStore: rootDir must be non-empty")
  createDir(rootDir)
  CaptureStore(rootDir: rootDir)

proc sha256OfBytes(bytes: openArray[byte]): string =
  ## sha256(bytes) → lowercase hex.  Shell-out matches the rest of
  ## the codebase (cmd_init.nim, manifest_hash.nim).  We use
  ## stdin/stdout instead of a temp file so the data never lands on
  ## disk except via the store itself.
  let exe = findExe("shasum")
  let cmd =
    if exe.len > 0: ("shasum", @["-a", "256"])
    else: ("sha256sum", @[])
  let p = startProcess(cmd[0], args = cmd[1],
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let stdin = p.inputStream
  var raw = newString(bytes.len)
  for i in 0 ..< bytes.len: raw[i] = char(bytes[i])
  stdin.write(raw)
  stdin.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    raise newException(CaptureStoreError,
      "CaptureStore: " & cmd[0] & " failed (" & $code & "): " & output)
  let parts = output.splitWhitespace()
  if parts.len == 0:
    raise newException(CaptureStoreError,
      "CaptureStore: " & cmd[0] & " returned empty output")
  parts[0].toLowerAscii()

proc pathFor*(store: CaptureStore; sha256: string): string =
  ## Return the canonical destination path for a digest.  Does
  ## *not* check whether the file exists.
  if sha256.len < 2:
    raise newException(CaptureStoreError,
      "CaptureStore.pathFor: sha256 must be at least 2 chars long")
  store.rootDir / sha256[0 .. 1] / (sha256 & ".png")

proc put*(store: CaptureStore; pngBytes: openArray[byte]):
    tuple[sha256: string; path: string] =
  ## Write ``pngBytes`` into the store.  Returns the digest and the
  ## canonical path.  Atomic + idempotent (see module doc).
  if pngBytes.len == 0:
    raise newException(CaptureStoreError,
      "CaptureStore.put: empty pngBytes")
  let sha = sha256OfBytes(pngBytes)
  let dest = store.pathFor(sha)
  let destDir = dest.parentDir
  createDir(destDir)

  if fileExists(dest):
    # Idempotency: if the canonical file is already there with the
    # right size, leave it untouched.  We trust the digest (re-
    # computing it adds I/O we don't need at retry time).
    let fi = getFileInfo(dest)
    if fi.size == pngBytes.len:
      return (sha256: sha, path: dest)

  let tmp = dest & ".tmp"
  block writeTmp:
    let f = open(tmp, fmWrite)
    defer: f.close()
    if pngBytes.len > 0:
      discard f.writeBuffer(unsafeAddr pngBytes[0], pngBytes.len)
  # ``os.moveFile`` uses ``rename(2)`` on POSIX which is atomic on
  # the same filesystem — exactly what the milestone's
  # ``test_capture_store_atomic_write`` asserts.
  moveFile(tmp, dest)
  result = (sha256: sha, path: dest)

proc get*(store: CaptureStore; sha256: string): seq[byte] =
  ## Read a stored PNG back as a byte buffer.  Raises
  ## ``CaptureStoreError`` if the file is missing.
  let path = store.pathFor(sha256)
  if not fileExists(path):
    raise newException(CaptureStoreError,
      "CaptureStore.get: no entry for sha256 " & sha256)
  let raw = readFile(path)
  result = newSeq[byte](raw.len)
  for i in 0 ..< raw.len: result[i] = byte(raw[i])
