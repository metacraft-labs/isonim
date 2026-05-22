## TBAR-M3 — headless ViewModel test for the editor's top-bar
## Preview / Spec surface toggle.
##
## Covers:
##
##   * ``EditorVM.surfaceSig`` defaults to ``sPreview``.
##   * Flipping ``surfaceSig`` via the public ``setSurface`` proc
##     drives subscriber notifications (a sentinel callback fires).
##   * The ``isPreviewOnlyControlsVisible`` predicate (used by the
##     shell to gate the property-inspector mount) returns ``false``
##     when ``surface == sSpec`` and ``true`` otherwise.

import std/unittest

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels

suite "TBAR-M3 editor surface toggle":

  test "editor_vm_defaults_surface_to_preview":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.surfaceSig != nil
      check vm.surfaceSig.val == sPreview
      dispose()

  test "set_surface_flips_signal_and_fires_subscribers":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      var observed: seq[Surface] = @[]
      # Subscribe via a render effect so we exercise the same reactive
      # surface the shell uses.
      createRenderEffect proc() =
        observed.add vm.surfaceSig.val
      check observed == @[sPreview]
      vm.setSurface(sSpec)
      check vm.surfaceSig.val == sSpec
      check observed == @[sPreview, sSpec]
      # Activating the same surface should not refire the effect — the
      # signal's default equality short-circuits identical writes.
      vm.setSurface(sSpec)
      check observed == @[sPreview, sSpec]
      vm.setSurface(sPreview)
      check observed == @[sPreview, sSpec, sPreview]
      dispose()

  test "direct_signal_write_drives_subscriber_callback":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      var ticks = 0
      createRenderEffect proc() =
        discard vm.surfaceSig.val
        inc ticks
      check ticks == 1
      vm.surfaceSig.val = sSpec
      check ticks == 2
      vm.surfaceSig.val = sPreview
      check ticks == 3
      dispose()

  test "is_preview_only_controls_visible_predicate_tracks_surface":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.isPreviewOnlyControlsVisible()
      vm.setSurface(sSpec)
      check not vm.isPreviewOnlyControlsVisible()
      vm.setSurface(sPreview)
      check vm.isPreviewOnlyControlsVisible()
      dispose()
