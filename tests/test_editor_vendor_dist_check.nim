## TBAR-M5b — integrity gate for the editor-vendor Nix derivation.
##
## Builds the ``editor-vendor`` flake output via ``nix build`` and
## asserts the resulting store path carries the expected UMD bundles
## (``tiptap.umd.js`` + ``xterm.umd.js``), a ``MANIFEST.txt`` recording
## a SHA-256 for each, and that each bundle is within its per-library
## byte budget.
##
## This test replaces the TBAR-M4 ``test_editor_spec_pane_vendor_present``
## file: the source-of-truth is no longer a committed UMD in the
## repo, it is the content-addressed Nix derivation output.

import std/[unittest, os, osproc, strutils]

const
  RepoRoot = currentSourcePath().parentDir().parentDir()

proc runOrFail(cmd: string): string =
  ## Run ``cmd``, fail the test with the captured output if the
  ## process exits non-zero, otherwise return stdout (stderr drained
  ## into stdout via ``poStdErrToStdOut``).
  let (output, exitCode) = execCmdEx(cmd, options = {poStdErrToStdOut,
                                                     poUsePath})
  if exitCode != 0:
    echo "command failed: ", cmd
    echo output
    fail()
  output

proc extractStorePath(rawOutput: string): string =
  ## ``nix build --print-out-paths`` interleaves status / warning lines
  ## (``warning: Git tree ... has uncommitted changes``,
  ## ``downloading...``, etc.) with the actual store path on the final
  ## line.  Strip everything but the last non-empty line that looks
  ## like a ``/nix/store/...`` path.
  for line in rawOutput.splitLines():
    let s = line.strip()
    if s.startsWith("/nix/store/"):
      result = s

proc nixBuildEditorVendor(): string =
  let cmd = "nix --extra-experimental-features 'nix-command flakes' " &
            "build --no-link --print-out-paths " & RepoRoot &
            "#editor-vendor"
  result = extractStorePath(runOrFail(cmd))

proc fileBytes(path: string): int64 =
  doAssert fileExists(path), "missing: " & path
  getFileInfo(path).size

suite "TBAR-M5b editor-vendor dist check":

  test "nix_build_editor_vendor_produces_expected_layout":
    ## ``nix build --print-out-paths`` returns the store path of the
    ## derivation output.  We then inspect that directory directly
    ## rather than relying on the local ``./result`` symlink (the
    ## ``--no-link`` option keeps the working tree clean).
    let outPath = nixBuildEditorVendor()
    check outPath.len > 0
    check dirExists(outPath)

    let tiptapBundle = outPath / "tiptap.umd.js"
    let xtermBundle = outPath / "xterm.umd.js"
    let manifest = outPath / "MANIFEST.txt"

    check fileExists(tiptapBundle)
    check fileExists(xtermBundle)
    check fileExists(manifest)

    # Per-library byte budgets from the milestone brief.
    let tiptapKb = fileBytes(tiptapBundle) div 1024
    let xtermKb = fileBytes(xtermBundle) div 1024
    if tiptapKb >= 800:
      echo "tiptap.umd.js is ", tiptapKb, " KB — budget is < 800 KB"
    if xtermKb >= 300:
      echo "xterm.umd.js is ", xtermKb, " KB — budget is < 300 KB"
    check tiptapKb < 800
    check xtermKb < 300

  test "manifest_carries_a_well_formed_sha256_for_each_bundle":
    let outPath = nixBuildEditorVendor()
    let manifest = readFile(outPath / "MANIFEST.txt")
    # Each bundle name must appear on a line carrying a 64-character
    # hex SHA-256.
    for label in ["tiptap.umd.js", "xterm.umd.js"]:
      var sawSha = false
      for line in manifest.splitLines():
        if not line.contains(label):
          continue
        var i = 0
        while i + 64 <= line.len:
          var allHex = true
          for j in 0 ..< 64:
            let ch = line[i + j]
            if not (ch.isDigit or
                    (ch >= 'a' and ch <= 'f') or
                    (ch >= 'A' and ch <= 'F')):
              allHex = false
              break
          if allHex:
            sawSha = true
            break
          inc i
        if sawSha: break
      if not sawSha:
        echo "MANIFEST.txt missing a SHA-256 for ", label
      check sawSha

  test "bundles_attach_named_globalThis_namespaces":
    let outPath = nixBuildEditorVendor()
    let tiptap = readFile(outPath / "tiptap.umd.js")
    let xterm = readFile(outPath / "xterm.umd.js")
    # The per-library FFI modules pick up the bundle's exports via
    # ``globalThis.TipTap`` / ``TipTapStarterKit`` / ``TipTapMarkdown``
    # / ``TipTapLink`` / ``XtermTerminal``.  Grep the minified output
    # for the property-access strings the IIFE writes.
    check tiptap.contains("globalThis.TipTap")
    check tiptap.contains("TipTapStarterKit")
    check tiptap.contains("TipTapMarkdown")
    # CHRM-M4: ``@tiptap/extension-link`` is now part of the TipTap
    # bundle so the spec-pane formatting toolbar's Link button has a
    # ``setLink`` / ``unsetLink`` command surface and the ``link``
    # mark resolves for ``isActive('link')`` queries.
    check tiptap.contains("TipTapLink")
    check xterm.contains("globalThis.XtermTerminal")
