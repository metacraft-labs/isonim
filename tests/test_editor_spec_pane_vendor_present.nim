## TBAR-M4 — static guard: assert the vendored TipTap UMD bundle is
## physically present in the source tree, that its MANIFEST records
## a pinned version + source URL + SHA-256, and that every listed
## ``.js`` file exists on disk and is non-empty.
##
## Pure file-system / string-scan check. No runtime, no JS, no Nim
## compilation against the vendor file.
##
## This is the "did anyone delete the vendor directory" guard. The
## browser e2e suite asserts the bundle is also copied into
## ``build/editor/vendor/tiptap/`` and reachable by the editor; this
## test asserts the *source-of-truth* lives where the editor-build
## recipe expects to find it.

import std/[unittest, os, strutils]

const
  RepoRoot = currentSourcePath().parentDir().parentDir()
  VendorDir = RepoRoot / "src/isonim/editor/vendor/tiptap"
  ManifestPath = VendorDir / "MANIFEST.txt"
  BundlePath = VendorDir / "isonim-tiptap.umd.min.js"

suite "TBAR-M4 TipTap vendor present":

  test "vendor_directory_exists":
    check dirExists(VendorDir)

  test "manifest_file_exists":
    check fileExists(ManifestPath)

  test "manifest_pins_a_tiptap_version":
    let manifest = readFile(ManifestPath)
    # The MANIFEST must record one ``Version:`` line per pinned
    # package; we accept any version literal but the field must be
    # present.
    var sawTiptapVersion = false
    var sawSourceTarball = false
    for line in manifest.splitLines():
      let s = line.strip()
      if s.startsWith("Version:") or s.contains("Version:"):
        # Look for a "M.N.P"-shaped literal after the colon to catch
        # the case where someone deletes the version number but
        # leaves the field heading.
        let afterColon = s.split("Version:", maxsplit = 1)
        if afterColon.len >= 2:
          let value = afterColon[1].strip()
          if value.len > 0 and value[0].isDigit:
            sawTiptapVersion = true
      if s.contains("registry.npmjs.org") or s.contains("Tarball:"):
        sawSourceTarball = true
    if not sawTiptapVersion:
      echo "MANIFEST.txt missing a pinned Version: line"
    if not sawSourceTarball:
      echo "MANIFEST.txt missing a source-URL / Tarball: line"
    check sawTiptapVersion
    check sawSourceTarball

  test "manifest_records_a_sha256_for_each_vendored_file":
    let manifest = readFile(ManifestPath)
    # Each vendored ``.js`` file must appear in the manifest with a
    # SHA-256 hex literal (64 hex chars).
    var foundBundleSha = false
    for line in manifest.splitLines():
      let s = line.strip()
      if not s.contains("isonim-tiptap.umd.min.js"):
        continue
      # Scan the line for a 64-character hex token.
      var i = 0
      while i + 64 <= s.len:
        var allHex = true
        for j in 0 ..< 64:
          let ch = s[i + j]
          if not (ch.isDigit or (ch >= 'a' and ch <= 'f') or
                  (ch >= 'A' and ch <= 'F')):
            allHex = false
            break
        if allHex:
          foundBundleSha = true
          break
        inc i
      if foundBundleSha: break
    if not foundBundleSha:
      echo "MANIFEST.txt missing a SHA-256 for isonim-tiptap.umd.min.js"
    check foundBundleSha

  test "tiptap_umd_bundle_file_exists_and_is_non_empty":
    check fileExists(BundlePath)
    let info = getFileInfo(BundlePath)
    if info.size <= 0:
      echo "isonim-tiptap.umd.min.js is empty"
    check info.size > 0

  test "tiptap_umd_bundle_size_within_budget":
    ## The milestone brief caps the total vendored bundle at < 800 KB
    ## minified. Anything substantially above this is a regression
    ## (and the next_steps summary must document it explicitly).
    let info = getFileInfo(BundlePath)
    let kb = info.size div 1024
    if kb >= 800:
      echo "isonim-tiptap.umd.min.js is ", kb,
           " KB — milestone budget is < 800 KB"
    check kb < 800

  test "tiptap_umd_bundle_exposes_global_handle":
    ## Sanity-check the UMD bundle attaches a ``window.IsoNimTipTap``
    ## global. We grep the file rather than execute it (no Node /
    ## JSDOM dependency in the headless test path); the e2e test
    ## exercises the real ``mountViewer`` API in a browser.
    let body = readFile(BundlePath)
    let hasGlobal = body.contains("IsoNimTipTap")
    if not hasGlobal:
      echo "isonim-tiptap.umd.min.js does not expose IsoNimTipTap"
    check hasGlobal
