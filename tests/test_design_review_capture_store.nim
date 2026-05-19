## REV-M5 — capture-store unit tests.
##
## Each test owns an ephemeral tmpdir.  We verify the store is
## content-addressed (path == ``<rootDir>/<sha[0:2]>/<sha>.png``)
## and that the write is atomic — a partial ``<sha>.png.tmp`` is
## acceptable, but ``<sha>.png`` MUST never appear truncated.

import std/[os, times, unittest]

import isonim/editor/design_review/capture_store

proc tmpRoot(suffix: string): string =
  result = getTempDir() / ("isonim_capture_store_" & suffix &
                           "_" & $epochTime().int)
  removeDir(result)
  createDir(result)

proc sample(): seq[byte] =
  # Deterministic 64-byte buffer so the test reproducibly hashes to
  # the same digest.
  result = newSeq[byte](64)
  for i in 0 ..< 64: result[i] = byte(i)

suite "REV-M5 capture store":

  test "test_capture_store_write_is_content_addressed":
    let root = tmpRoot("addressed")
    defer: removeDir(root)
    let store = newCaptureStore(root)
    let bytes = sample()
    let first = store.put(bytes)
    check first.sha256.len == 64
    let prefix = first.sha256[0 .. 1]
    check first.path == root / prefix / (first.sha256 & ".png")
    check fileExists(first.path)

    # Idempotency: second put returns the same path and does not
    # rewrite the file (mtime unchanged).
    let fi1 = getFileInfo(first.path)
    sleep(50)  # mtime resolution is sub-second on macOS APFS, but
                # the idempotency contract is "file untouched", so any
                # value that survives a real rewrite works.
    let second = store.put(bytes)
    check second.sha256 == first.sha256
    check second.path == first.path
    let fi2 = getFileInfo(first.path)
    check fi2.lastWriteTime == fi1.lastWriteTime

  test "test_capture_store_atomic_write":
    let root = tmpRoot("atomic")
    defer: removeDir(root)
    let store = newCaptureStore(root)
    let bytes = sample()
    let first = store.put(bytes)

    # Simulate a previous crash mid-write by manually creating
    # the .tmp sibling and ensuring the final put is still atomic.
    let tmpPath = first.path & ".tmp"
    writeFile(tmpPath, "partial bytes")
    check fileExists(tmpPath)

    # The .tmp sibling exists, the canonical file already exists
    # (idempotent path): a subsequent put must not delete the canonical
    # file and must not propagate the partial bytes.
    let second = store.put(bytes)
    check second.path == first.path
    check fileExists(first.path)

    # Now simulate the inverse: a partial .tmp without a finished
    # canonical file.  We remove the canonical, leave the bogus .tmp,
    # and put fresh bytes.  The new .png MUST appear with the exact
    # length of the input, never the partial bytes.
    removeFile(first.path)
    writeFile(tmpPath, "still partial")
    let third = store.put(bytes)
    let fi = getFileInfo(third.path)
    check fi.size == bytes.len

    # And there must be no leftover .tmp at the destination (moveFile
    # consumed it).
    check (not fileExists(tmpPath))
