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
##   ``rb_hcr_*`` symbols from Reprobuild's ``libct_hcr_agent`` and
##   ``-lct_hcr_agent`` is added to the link command. When the flag is
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
##   ``codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload-Native.md``
##   § "How Reprobuild HCR participates" lists the FFI surface IsoNim
##   consumes.
## - Native HMR milestones:
##   ``codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload-Native.milestones.org``
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

type
  RbHcrTypeChange* = object
    ## Per-type layout-change descriptor handed to before/after-reload
    ## callbacks. Mirrors the C ``RbHcrTypeChange`` struct (see Reprobuild
    ## HCR-Overview § 13.3). The Nim object layout is `{.bycopy.}` by
    ## default for non-`ref` `object` types, which matches the C struct
    ## layout the agent expects.
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

  RbHcrReloadCallback* = proc (info: ptr RbHcrReloadInfo;
      userData: pointer) {.cdecl.}
    ## C-callable callback signature used by both before- and
    ## after-reload registration. ``{.cdecl.}`` is mandatory: the
    ## Reprobuild agent invokes these directly from C code and assumes
    ## the platform C calling convention.

# ---------------------------------------------------------------------------
# FFI surface — active path (``-d:reprobuildHcr``).
# ---------------------------------------------------------------------------

when defined(reprobuildHcr):
  {.passL: "-lct_hcr_agent".}

  proc rbHcrWantsReload*(): bool
    {.importc: "rb_hcr_wants_reload", header: "reprobuild/hcr.h".}

  proc rbHcrApplyReload*()
    {.importc: "rb_hcr_apply_reload", header: "reprobuild/hcr.h".}

  proc rbHcrRegisterManagedType*(typeName: cstring)
    {.importc: "rb_hcr_register_managed_type",
      header: "reprobuild/hcr.h".}

  proc rbHcrUnregisterManagedType*(typeName: cstring)
    {.importc: "rb_hcr_unregister_managed_type",
      header: "reprobuild/hcr.h".}

  proc rbHcrBeforeReload*(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_before_reload", header: "reprobuild/hcr.h".}

  proc rbHcrAfterReload*(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_after_reload", header: "reprobuild/hcr.h".}

  proc rbHcrRemoveBeforeReload*(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_remove_before_reload",
      header: "reprobuild/hcr.h".}

  proc rbHcrRemoveAfterReload*(callback: RbHcrReloadCallback;
      userData: pointer)
    {.importc: "rb_hcr_remove_after_reload",
      header: "reprobuild/hcr.h".}

  proc rbHcrFileChanged*(filePath: cstring): bool
    {.importc: "rb_hcr_file_changed", header: "reprobuild/hcr.h".}

  proc rbHcrTypeChanged*(typeName: cstring): bool
    {.importc: "rb_hcr_type_changed", header: "reprobuild/hcr.h".}

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
  proc rbHcrWantsReload*(): bool =
    ## No-op fallback: Reprobuild HCR isn't linked, so no patch is ever
    ## pending.
    false

  proc rbHcrApplyReload*() =
    ## No-op fallback: applying a non-existent patch is a no-op.
    discard

  proc rbHcrRegisterManagedType*(typeName: cstring) =
    ## No-op fallback: managed-type registration is meaningless without
    ## the agent. Callers can register types unconditionally; if HCR is
    ## off the call is silently dropped.
    discard

  proc rbHcrUnregisterManagedType*(typeName: cstring) =
    ## No-op fallback.
    discard

  proc rbHcrBeforeReload*(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback: with no agent there's no reload event, so the
    ## callback is simply never invoked. We deliberately do *not* hold
    ## onto the callback pointer here — the no-op path has no registry.
    discard

  proc rbHcrAfterReload*(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback. See ``rbHcrBeforeReload`` for rationale.
    discard

  proc rbHcrRemoveBeforeReload*(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback: removing a never-registered callback is a no-op.
    discard

  proc rbHcrRemoveAfterReload*(callback: RbHcrReloadCallback;
      userData: pointer) =
    ## No-op fallback.
    discard

  proc rbHcrFileChanged*(filePath: cstring): bool =
    ## No-op fallback: with no agent there is no notion of a "changed
    ## file in the most recent reload", so every query returns ``false``.
    false

  proc rbHcrTypeChanged*(typeName: cstring): bool =
    ## No-op fallback: same reasoning as ``rbHcrFileChanged``.
    false

# ---------------------------------------------------------------------------
# TODO (NH-M2): expose Reprobuild's padded-allocation surface
# (``rb_hcr_padded_alloc`` / ``rb_hcr_padded_free`` /
# ``rb_hcr_padded_capacity`` — see Reprobuild HCR-Overview § 13.5). They
# are *not* required by NH-M0 since the NH-M1 reactive root scaffold does
# not allocate any managed-type instances. They will be introduced
# alongside the managed-type lifecycle work in NH-M2, where the signal
# storage migration path actually consumes them. Bringing them in here
# would add three more `importc`/no-op pairs without any caller — pure
# surface area for no benefit at this milestone.
# ---------------------------------------------------------------------------
