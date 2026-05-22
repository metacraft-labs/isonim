## TBAR-M4 — headless ViewModel test for the spec-pane VM.
##
## Covers the contract the milestone exposes:
##
##   * ``createSpecPaneVM("")`` produces ``mode == spmView`` and
##     ``markdown == ""``.
##   * ``createSpecPaneVM("# Hello\n")`` carries the markdown through
##     to ``vm.markdown.val``.
##   * Writing ``vm.markdown`` fires reactive subscribers.
##   * Writing ``vm.mode`` fires reactive subscribers.
##
## This is a pure VM test — no DOM, no TipTap, no browser. The
## vendor shim's native stub compiles ``mountTipTapViewer`` as a
## no-op so the import chain through ``spec_pane.nim`` is exercised
## but never executed.

import std/unittest

import isonim/core/[signals, computation, owner]
import isonim/editor/views/spec_pane

suite "TBAR-M4 spec pane VM":

  test "spec_pane_vm_defaults_mode_to_view_and_markdown_to_empty":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("")
      check vm.mode != nil
      check vm.markdown != nil
      check vm.mode.val == spmView
      check vm.markdown.val == ""
      dispose()

  test "spec_pane_vm_constructor_carries_initial_markdown":
    createRoot do (dispose: proc()):
      let body = "# Hello\n\nWelcome to the spec.\n"
      let vm = createSpecPaneVM(body)
      check vm.markdown.val == body
      check vm.mode.val == spmView
      dispose()

  test "spec_pane_vm_markdown_write_fires_subscribers":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("")
      var observed: seq[string] = @[]
      createRenderEffect proc() =
        observed.add vm.markdown.val
      check observed == @[""]
      vm.setMarkdown("# Hello\n")
      check vm.markdown.val == "# Hello\n"
      check observed == @["", "# Hello\n"]
      # Writing the same value is a no-op (signal equality
      # short-circuits identical writes).
      vm.setMarkdown("# Hello\n")
      check observed == @["", "# Hello\n"]
      # Direct signal write also notifies.
      vm.markdown.val = "## Updated\n"
      check observed == @["", "# Hello\n", "## Updated\n"]
      dispose()

  test "spec_pane_vm_mode_write_fires_subscribers":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("")
      var observed: seq[SpecPaneMode] = @[]
      createRenderEffect proc() =
        observed.add vm.mode.val
      check observed == @[spmView]
      vm.setMode(spmComment)
      check vm.mode.val == spmComment
      check observed == @[spmView, spmComment]
      vm.setMode(spmEdit)
      check observed == @[spmView, spmComment, spmEdit]
      # Re-activating the same mode is a no-op.
      vm.setMode(spmEdit)
      check observed == @[spmView, spmComment, spmEdit]
      # Direct signal write also notifies.
      vm.mode.val = spmView
      check observed == @[spmView, spmComment, spmEdit, spmView]
      dispose()
