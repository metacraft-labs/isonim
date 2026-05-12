## tests/test_native_hcr_shim.nim
##
## NH-M0 verification suite for the Reprobuild HCR FFI shim
## (``isonim/src/isonim/native/hcr.nim``). The shim is gated on
## ``-d:reprobuildHcr``; this test exercises the *inactive* path (the
## one IsoNim builds against by default until Reprobuild is installed),
## and additionally invokes a small symbol-absence check via ``nm`` to
## prove the zero-cost-when-off property at the link level — the third
## NH-M0 verification entry, ``test_hcr_shim_symbol_absence``, in the
## milestones file.
##
## The test is native-only (``nim c``). The companion `isonim/web/hmr`
## module covers the JS target.
##
## To exercise the active (linked) path manually:
##
##   direnv exec ~/metacraft/isonim nim c -d:reprobuildHcr -c \
##     tests/test_native_hcr_shim.nim
##
## (Compile-only — full linking requires ``libct_hcr_agent`` and
## ``reprobuild/hcr.h``, which only exist once Reprobuild itself is
## built. NH-M4 wires up the real-agent integration test.)

when defined(js):
  {.error: "test_native_hcr_shim is a native-only test (use `nim c -r`)".}

import std/[os, osproc, strutils, unittest]
import isonim/native/hcr

# A canary the callback path can flip so the test can verify the no-op
# fallback does *not* invoke registered callbacks. `{.global.}` keeps
# the storage at module scope so the `{.cdecl.}` callback can mutate it
# without capturing a closure.
var hcrShimCallbackHits {.global.}: int = 0

proc sampleCallback(info: ptr RbHcrReloadInfo;
                    userData: pointer) {.cdecl.} =
  inc hcrShimCallbackHits

suite "NH-M0 Reprobuild HCR FFI shim (no-op fallback path)":

  test "test_hcr_shim_no_op_returns_defaults":
    ## With ``-d:reprobuildHcr`` off, every introspection query must
    ## report the safe default and every mutator must be a no-op. This
    ## is what lets NH-M1+ call into the shim without per-call-site
    ## ``when`` guards.
    check rbHcrWantsReload() == false
    rbHcrApplyReload()  # must not raise

    check rbHcrFileChanged("anything") == false
    check rbHcrTypeChanged("anything") == false

    # Managed-type registration / unregistration are silent no-ops.
    rbHcrRegisterManagedType("isonim.SignalState")
    rbHcrUnregisterManagedType("isonim.SignalState")

    # Callback registration and removal — including for callbacks that
    # were never registered — must not raise.
    rbHcrBeforeReload(sampleCallback, nil)
    rbHcrAfterReload(sampleCallback, nil)
    rbHcrRemoveBeforeReload(sampleCallback, nil)
    rbHcrRemoveAfterReload(sampleCallback, nil)

  test "test_hcr_shim_compiles_without_flag":
    ## Trivially passes — the assertion here is that this file compiles
    ## and links at all without ``-d:reprobuildHcr``. If the no-op
    ## fallback path ever drops a proc or changes a signature, the
    ## whole binary fails to compile and this test is unreachable.
    check true

  test "test_hcr_shim_callback_type_signature":
    ## The ``RbHcrReloadCallback`` type is consumed both as a
    ## registration argument and (in NH-M2) as a value handed back to
    ## the framework from user code. Verify the cdecl shape compiles by
    ## binding a sample callback to both registration entry points,
    ## then assert that under the no-op path the callback is *not*
    ## invoked (the real agent is the only thing that fires it; the
    ## no-op shim must not synthesise reload events).
    hcrShimCallbackHits = 0
    rbHcrBeforeReload(sampleCallback, nil)
    rbHcrAfterReload(sampleCallback, nil)
    # Without an agent, calling apply_reload is a no-op and must not
    # invoke any registered callback.
    rbHcrApplyReload()
    check hcrShimCallbackHits == 0
    rbHcrRemoveBeforeReload(sampleCallback, nil)
    rbHcrRemoveAfterReload(sampleCallback, nil)

  test "test_hcr_shim_symbol_absence":
    ## Zero-cost-when-off at the *link* level: compile a tiny program
    ## that imports the shim without ``-d:reprobuildHcr`` and verify
    ## that none of the ``rb_hcr_`` C symbols are referenced by the
    ## resulting binary. If any leak in, this test fails and points to
    ## a missing ``when`` guard in ``isonim/native/hcr.nim``.
    ##
    ## The probe program is a one-liner that imports the shim and
    ## consumes one symbol from the no-op surface — enough to force the
    ## compiler to keep the module rather than dead-strip it before we
    ## inspect it.
    let
      testDir = currentSourcePath().parentDir
      repoDir = testDir.parentDir
      srcDir = repoDir / "src"
      buildDir = testDir / "_build"
      probeSrc = buildDir / "hcr_shim_probe.nim"
      probeBin = buildDir / "hcr_shim_probe"
    createDir(buildDir)
    writeFile(probeSrc, """
import isonim/native/hcr

# Touch every exported proc so the linker can't dead-strip the module.
# Under the no-op path this expands to plain Nim bodies with no
# `rb_hcr_*` C references whatsoever.
discard rbHcrWantsReload()
rbHcrApplyReload()
rbHcrRegisterManagedType(cstring"probe")
rbHcrUnregisterManagedType(cstring"probe")
discard rbHcrFileChanged(cstring"probe")
discard rbHcrTypeChanged(cstring"probe")

proc cb(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} = discard
rbHcrBeforeReload(cb, nil)
rbHcrAfterReload(cb, nil)
rbHcrRemoveBeforeReload(cb, nil)
rbHcrRemoveAfterReload(cb, nil)
""")
    # Build the probe without ``-d:reprobuildHcr``. The probe lives
    # under tests/_build/ so it doesn't inherit ``tests/config.nims``;
    # supply ``--path`` explicitly so ``isonim/native/hcr`` resolves.
    let compileCmd = "nim c --hints:off --warnings:off " &
        "--path:" & quoteShell(srcDir) & " " &
        "-o:" & quoteShell(probeBin) & " " &
        quoteShell(probeSrc)
    let (compileOut, compileCode) = execCmdEx(compileCmd,
        workingDir = testDir)
    if compileCode != 0:
      echo compileOut
    check compileCode == 0

    if compileCode == 0:
      # Inspect the binary's symbol table for stray ``rb_hcr_`` symbols.
      let (nmOut, nmCode) = execCmdEx("nm -a " & quoteShell(probeBin))
      check nmCode == 0
      var leakedSymbols: seq[string] = @[]
      for line in nmOut.splitLines:
        if line.contains("rb_hcr_"):
          leakedSymbols.add(line.strip)
      if leakedSymbols.len > 0:
        echo "Unexpected rb_hcr_ symbols leaked into the no-op build:"
        for sym in leakedSymbols:
          echo "  ", sym
      check leakedSymbols.len == 0
