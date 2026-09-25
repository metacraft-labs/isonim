## isonim/native/hcr.nim
##
## Nim FFI shim for the Reprobuild Hot Code Reloading (HCR) provider —
## the surface every native IsoNim renderer rides on top of to gain
## hot-module-reload semantics. This module is *infrastructure-only*: it
## declares the procs and types that NH-M1+ build on top of. It performs
## no reactive-root work, no per-renderer reconciliation, and no
## generation accounting. Those are explicit follow-up milestones (see
## the milestones file referenced below).
##
## ## Compile-time gates
##
## Two independent gates govern native HMR. Both must be on for HMR to
## function; with either one off, IsoNim is byte-identical to today's
## production output for the affected layer.
##
## - ``-d:reprobuildHcr`` — toggles **this** module's FFI bindings.
##   When the flag is on, the procs below `importc` the real
##   ``rb_hcr_*`` symbols from Reprobuild's ``librepro_hcr_agent`` and
##   ``-lrepro_hcr_agent`` is added to the link command. When the flag is
##   off, every proc has a no-op fallback body with the same signature,
##   so call sites in higher layers do **not** need ``when`` blocks per
##   call.
##
## - ``-d:isonimHmr`` — toggles IsoNim's own HMR machinery
##   (signal registry, ui-block versioning, reactive-root swap). That is
##   wired up in NH-M2's ``isonim/native/hmr.nim``; it is **not** this
##   module's concern.
##
## ## Why a single seam module
##
## NH-M1+ all consume the symbols declared here. By centralising the
## ``when defined(reprobuildHcr)`` split in one place we avoid scattering
## conditional compilation through the renderer code. The shape of the
## surface — Nim-native names, plain types — is identical under both
## paths, so callers can simply call ``rbHcrWantsReload()`` etc. without
## thinking about whether Reprobuild is linked in.
##
## ## Source-of-truth references
##
## - Native HMR design spec:
##   ``isonim-specs/Hot-Module-Reload-Native.md``
##   § "How Reprobuild HCR participates" lists the FFI surface IsoNim
##   consumes.
## - Native HMR milestones:
##   ``isonim-specs/Hot-Module-Reload-Native.milestones.org``
##   § "NH-M0" pins this module's scope and verification tests.
## - Reprobuild HCR C API (canonical):
##   ``metacraft/reprobuild-specs/HCR/HCR-Overview.md`` § 13
##   "Application Runtime API". The C signatures we mirror live there.

when defined(js):
  {.error: "isonim/native/hcr is for native (nim c) targets only. " &
      "The JS HMR runtime lives in isonim/web/hmr.nim.".}

# ---------------------------------------------------------------------------
# Public types — shared by both the FFI and the no-op fallback paths.
# Keeping them outside the `when defined(reprobuildHcr)` split means the
# callable surface is identical regardless of gating, so callers can rely on
# the layout of `RbHcrReloadInfo` / `RbHcrTypeChange` and the
# `RbHcrReloadCallback` calling convention with no `when` ladder of their own.
# ---------------------------------------------------------------------------

when defined(reprobuildHcr):
  type
    RbHcrTypeChange* {.importc: "RbHcrTypeChange", header: "repro_hcr_agent.h", bycopy.} = object
      ## Per-type layout-change descriptor handed to before/after-reload
      ## callbacks. Mirrors the C ``RbHcrTypeChange`` struct (see Reprobuild
      ## HCR-Overview § 13.3).
      ##
      ## NH-M2: the per-field ``importc`` pragmas are load-bearing and were
      ## missing. Without them Nim emits the camelCase Nim spelling into the
      ## generated C (``x.typeName``) while the header declares ``type_name``,
      ## so any code that READS a field fails to compile under
      ## ``-d:reprobuildHcr``. NH-M0 never read one — its callback body only
      ## increments a counter — which is why the mismatch survived four
      ## months behind a green gate.
      typeName* {.importc: "type_name".}: cstring
      oldSize* {.importc: "old_size".}: uint32
      newSize* {.importc: "new_size".}: uint32

    RbHcrReloadInfo* {.importc: "const RbHcrReloadInfo", header: "repro_hcr_agent.h", bycopy.} = object
      ## Reload context passed to before/after-reload callbacks. Pointer +
      ## count pairs mirror the C structure (`const char* const*` becomes
      ## ``ptr UncheckedArray[cstring]``). The C agent owns this storage;
      ## IsoNim must not retain pointers past the callback's return.
      ##
      ## See the note on ``RbHcrTypeChange`` for why each field carries its
      ## own ``importc``.
      changedFiles* {.importc: "changed_files".}: ptr UncheckedArray[cstring]
      changedFilesCount* {.importc: "changed_files_count".}: uint32
      changedTypes* {.importc: "changed_types".}: ptr UncheckedArray[RbHcrTypeChange]
      changedTypesCount* {.importc: "changed_types_count".}: uint32
      codeSwapped* {.importc: "code_swapped".}: cint
        ## OPEN-5, decided 2026-09-20 in Reprobuild: non-zero iff the code swap
        ## has actually happened by the time this callback runs. Zero
        ## ``changedTypesCount`` alone is ambiguous — it is what a late load
        ## failure delivers (Patch-Loading-Lifecycle § 3.3 step 38) and equally
        ## what an ordinary no-layout-change patch delivers. A before-reload
        ## callback sees 0; an after-reload callback on a reload that committed
        ## sees 1; an after-reload callback on a step-38 failure sees 0.
        ##
        ## IsoNim does not need it: the native HMR path is correct WITHOUT
        ## detecting the case, because the entry re-runs against unpatched
        ## bodies, re-registers the hashes already present, and every slot is
        ## re-claimed so nothing is pruned. It is bound because the portable ABI
        ## now carries it and a binding that silently omits a field is how the
        ## two sides drift.

    RbHcrReloadCallback* {.importc: "RbHcrReloadCallback", header: "repro_hcr_agent.h".} = proc (info: ptr RbHcrReloadInfo;
        userData: pointer) {.cdecl.}
      ## C-callable callback signature used by both before- and
      ## after-reload registration. ``{.cdecl.}`` is mandatory: the
      ## Reprobuild agent invokes these directly from C code and assumes
      ## the platform C calling convention.

else:
  type
    RbHcrTypeChange* = object
      ## Per-type layout-change descriptor handed to before/after-reload
      ## callbacks. Mirrors the C ``RbHcrTypeChange`` struct (see Reprobuild
      ## HCR-Overview § 13.3).
      typeName*: cstring
      oldSize*: uint32
      newSize*: uint32

    RbHcrReloadInfo* = object
      ## Reload context passed to before/after-reload callbacks. Pointer +
      ## count pairs mirror the C structure (`const char* const*` becomes
      ## ``ptr UncheckedArray[cstring]``). The C agent owns this storage;
      ## IsoNim must not retain pointers past the callback's return.
      changedFiles*: ptr UncheckedArray[cstring]
      changedFilesCount*: uint32
      changedTypes*: ptr UncheckedArray[RbHcrTypeChange]
      changedTypesCount*: uint32
      codeSwapped*: cint
        ## Mirrors the C field appended for OPEN-5 (2026-09-20). This branch
        ## compiles without the agent header, so the layout is maintained by
        ## hand and MUST stay in the same order as the importc branch above.

    RbHcrReloadCallback* = proc (info: ptr RbHcrReloadInfo;
        userData: pointer) {.cdecl.}
      ## C-callable callback signature used by both before- and
      ## after-reload registration. ``{.cdecl.}`` is mandatory: the
      ## Reprobuild agent invokes these directly from C code and assumes
      ## the platform C calling convention.

# ---------------------------------------------------------------------------
# FFI surface — active path (``-d:reprobuildHcr``).
#
# NH-M2 note on the ``Raw`` suffix. These are the *bindings*; the names
# IsoNim code calls (``rbHcrBeforeReload`` etc., no suffix) are the thin
# wrappers further down, which are shared by both gating paths. Splitting
# the two layers is what lets ``-d:isonimHmr`` interpose a test agent
# (``isonim/tests/helpers/hcr_stub.nim``) without any call site changing
# shape. The C symbol names and signatures are unchanged — NH-M5 / HX-S-0's
# link gate greps ``nm`` for exactly these ten.
# ---------------------------------------------------------------------------

when defined(reprobuildHcr):
  {.passL: "-lrepro_hcr_agent".}

  proc rbHcrWantsReloadRaw(): bool
    {.importc: "rb_hcr_wants_reload", header: "repro_hcr_agent.h".}

  proc rbHcrApplyReloadRaw()
    {.importc: "rb_hcr_apply_reload", header: "repro_hcr_agent.h".}

  proc rbHcrRegisterManagedTypeRaw(typeName: cstring)
    {.importc: "rb_hcr_register_managed_type",
      header: "repro_hcr_agent.h".}

  proc rbHcrUnregisterManagedTypeRaw(typeName: cstring)
    {.importc: "rb_hcr_unregister_managed_type",
      header: "repro_hcr_agent.h".}

  proc rbHcrBeforeReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_before_reload", header: "repro_hcr_agent.h".}

  proc rbHcrAfterReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_after_reload", header: "repro_hcr_agent.h".}

  proc rbHcrRemoveBeforeReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_remove_before_reload",
      header: "repro_hcr_agent.h".}

  proc rbHcrRemoveAfterReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_remove_after_reload",
      header: "repro_hcr_agent.h".}

  proc rbHcrFileChangedRaw(filePath: cstring): bool
    {.importc: "rb_hcr_file_changed", header: "repro_hcr_agent.h".}

  proc rbHcrTypeChangedRaw(typeName: cstring): bool
    {.importc: "rb_hcr_type_changed", header: "repro_hcr_agent.h".}

# ---------------------------------------------------------------------------
# No-op fallback surface — inactive path (``-d:reprobuildHcr`` off).
#
# Identical names and signatures to the FFI path. The bodies are trivially
# zero-cost (constant returns / `discard`) so that even with `-d:release`
# disabled the inactive path produces no externally visible behaviour.
# Crucially, these procs are pure Nim — they emit no `rb_hcr_*` C symbols,
# which is what the NH-M0 symbol-absence verification test asserts at the
# link level.
# ---------------------------------------------------------------------------

else:
  proc rbHcrWantsReloadRaw(): bool =
    ## No-op fallback: Reprobuild HCR isn't linked, so no patch is ever
    ## pending.
    false

  proc rbHcrApplyReloadRaw() =
    ## No-op fallback: applying a non-existent patch is a no-op.
    discard

  proc rbHcrRegisterManagedTypeRaw(typeName: cstring) =
    ## No-op fallback: managed-type registration is meaningless without
    ## the agent. Callers can register types unconditionally; if HCR is
    ## off the call is silently dropped.
    discard

  proc rbHcrUnregisterManagedTypeRaw(typeName: cstring) =
    ## No-op fallback.
    discard

  proc rbHcrBeforeReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback: with no agent there's no reload event, so the
    ## callback is simply never invoked. We deliberately do *not* hold
    ## onto the callback pointer here — the no-op path has no registry.
    discard

  proc rbHcrAfterReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback. See ``rbHcrBeforeReloadRaw`` for rationale.
    discard

  proc rbHcrRemoveBeforeReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback: removing a never-registered callback is a no-op.
    discard

  proc rbHcrRemoveAfterReloadRaw(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback.
    discard

  proc rbHcrFileChangedRaw(filePath: cstring): bool =
    ## No-op fallback: with no agent there is no notion of a "changed
    ## file in the most recent reload", so every query returns ``false``.
    false

  proc rbHcrTypeChangedRaw(typeName: cstring): bool =
    ## No-op fallback: same reasoning as ``rbHcrFileChangedRaw``.
    false

# ---------------------------------------------------------------------------
# NH-M2 — the agent-hook seam (``-d:isonimHmr`` only).
#
# The ten functions above are the only surface IsoNim binds. There is no
# runnable Linux implementation of them yet: Reprobuild's shipped
# ``librepro_hcr_agent`` exports *baseline* bodies (`repro_hcr_agent.c`,
# "Application Runtime ABI: rb_hcr_*") whose ``wants_reload`` is a constant
# ``false`` and whose ``apply_reload`` is an explicit no-op; dynamic patch
# delivery, live callback dispatch and managed-type layout checking are all
# owned by Reprobuild ``HLX-M8``, which is ``planned``.
#
# So the only way to exercise IsoNim's reload lifecycle today is to stand a
# test agent in the real agent's place. ``HcrAgentHooks`` is that seam: when
# a hook is non-nil it *replaces* the corresponding shim call, so the
# application's own code path — ``if rbHcrWantsReload(): rbHcrApplyReload()``,
# ``rbHcrBeforeReload(cb, ud)`` — is byte-for-byte the path it will take
# against the real agent. The double is ``isonim/tests/helpers/hcr_stub.nim``.
#
# Gated on ``-d:isonimHmr``, not merely on "tests", for two reasons: the
# non-HMR production build must remain exactly what NH-M0 shipped (the
# symbol-absence gate compiles its probe with neither flag), and a seam that
# only exists in a test build is a seam the shipped code has never run
# through.
# ---------------------------------------------------------------------------

when defined(isonimHmr):
  type
    HcrAgentHooks* = ref object
      ## A stand-in for the HCR agent. Every field is optional; a nil field
      ## means "let the shim handle it". A non-nil field REPLACES the shim
      ## call rather than augmenting it, so exactly one registry sees each
      ## registration and callbacks cannot be double-fired.
      registerManagedType*: proc(typeName: cstring) {.closure.}
      unregisterManagedType*: proc(typeName: cstring) {.closure.}
      beforeReload*: proc(callback: RbHcrReloadCallback;
                          userData: pointer) {.closure.}
      afterReload*: proc(callback: RbHcrReloadCallback;
                         userData: pointer) {.closure.}
      removeBeforeReload*: proc(callback: RbHcrReloadCallback;
                                userData: pointer) {.closure.}
      removeAfterReload*: proc(callback: RbHcrReloadCallback;
                               userData: pointer) {.closure.}
      wantsReload*: proc(): bool {.closure.}
      applyReload*: proc() {.closure.}
      fileChanged*: proc(filePath: cstring): bool {.closure.}
      typeChanged*: proc(typeName: cstring): bool {.closure.}

  var hcrAgentHooks*: HcrAgentHooks
    ## The installed stand-in, or nil (the default) to go straight to the
    ## shim. Set by ``isonim/tests/helpers/hcr_stub.nim``'s
    ## ``installHcrStub``; cleared by ``uninstall``.

# ---------------------------------------------------------------------------
# Public surface — one wrapper layer shared by both gating paths.
#
# These are the names every IsoNim caller uses. Under ``-d:isonimHmr`` they
# consult ``hcrAgentHooks`` first; otherwise (and always in a production
# build) they are a direct forward to the layer above, which the C compiler
# inlines away.
# ---------------------------------------------------------------------------

proc rbHcrWantsReload*(): bool =
  ## True when a compiled patch is pending. HCR-Overview § 13.1.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.wantsReload != nil:
      return hcrAgentHooks.wantsReload()
  rbHcrWantsReloadRaw()

proc rbHcrApplyReload*() =
  ## Apply the pending patch now, running the full lifecycle
  ## (before-reload callbacks → patch application → after-reload
  ## callbacks). HCR-Overview § 13.1.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.applyReload != nil:
      hcrAgentHooks.applyReload()
      return
  rbHcrApplyReloadRaw()

proc rbHcrRegisterManagedType*(typeName: cstring) =
  ## Whitelist a type whose layout may change across a patch.
  ## HCR-Overview § 13.2 / § 7.4.
  ##
  ## The agent stores the POINTER, not a copy (see
  ## ``repro_hcr_agent.c``'s ``rb_hcr_register_managed_type``), so the
  ## caller owns keeping the string alive for the process lifetime.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.registerManagedType != nil:
      hcrAgentHooks.registerManagedType(typeName)
      return
  rbHcrRegisterManagedTypeRaw(typeName)

proc rbHcrUnregisterManagedType*(typeName: cstring) =
  ## Remove a type from the managed whitelist. HCR-Overview § 13.2.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.unregisterManagedType != nil:
      hcrAgentHooks.unregisterManagedType(typeName)
      return
  rbHcrUnregisterManagedTypeRaw(typeName)

proc rbHcrBeforeReload*(callback: RbHcrReloadCallback; userData: pointer) =
  ## Register a callback to run BEFORE the patch is applied.
  ## HCR-Overview § 13.3.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.beforeReload != nil:
      hcrAgentHooks.beforeReload(callback, userData)
      return
  rbHcrBeforeReloadRaw(callback, userData)

proc rbHcrAfterReload*(callback: RbHcrReloadCallback; userData: pointer) =
  ## Register a callback to run AFTER the patch is applied.
  ## HCR-Overview § 13.3.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.afterReload != nil:
      hcrAgentHooks.afterReload(callback, userData)
      return
  rbHcrAfterReloadRaw(callback, userData)

proc rbHcrRemoveBeforeReload*(callback: RbHcrReloadCallback;
                              userData: pointer) =
  ## Remove a before-reload callback, matched by (function, user_data).
  ## HCR-Overview § 13.3.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.removeBeforeReload != nil:
      hcrAgentHooks.removeBeforeReload(callback, userData)
      return
  rbHcrRemoveBeforeReloadRaw(callback, userData)

proc rbHcrRemoveAfterReload*(callback: RbHcrReloadCallback;
                             userData: pointer) =
  ## Remove an after-reload callback, matched by (function, user_data).
  ## HCR-Overview § 13.3.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.removeAfterReload != nil:
      hcrAgentHooks.removeAfterReload(callback, userData)
      return
  rbHcrRemoveAfterReloadRaw(callback, userData)

proc rbHcrFileChanged*(filePath: cstring): bool =
  ## True iff the most recent **applied** reload listed this file.
  ## HCR-Overview § 13.4, with the applied-not-requested rule pinned by
  ## GDScript-Hot-Reload-Multi-Version-Sources § 4.5 (and restated in the
  ## baseline C body's own comment).
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.fileChanged != nil:
      return hcrAgentHooks.fileChanged(filePath)
  rbHcrFileChangedRaw(filePath)

proc rbHcrTypeChanged*(typeName: cstring): bool =
  ## True iff the most recent applied reload changed this type's layout.
  ## HCR-Overview § 13.4.
  when defined(isonimHmr):
    if hcrAgentHooks != nil and hcrAgentHooks.typeChanged != nil:
      return hcrAgentHooks.typeChanged(typeName)
  rbHcrTypeChangedRaw(typeName)

# ---------------------------------------------------------------------------
# NOT exposed here: Reprobuild's padded-allocation surface
# (``rb_hcr_padded_alloc`` / ``rb_hcr_padded_free`` /
# ``rb_hcr_padded_capacity`` — HCR-Overview § 13.5).
#
# NH-M0 deferred these to NH-M2 on the assumption that NH-M2's signal
# storage would consume them. It does not: the native HMR registry keeps
# ``SignalState[T]`` instances behind a ``ref`` (the Pimpl shape
# HCR-Overview § 7.5 describes), so the handle IsoNim holds has a fixed
# one-word layout and a value-type growth never has to fit in a padding
# budget. Bringing the three procs in would still add surface with no
# caller. They belong with whatever first allocates a managed instance
# inline — not here.
# ---------------------------------------------------------------------------
