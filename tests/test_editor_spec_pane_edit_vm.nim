## TBAR-M5 — headless ViewModel test for the spec-pane edit / save
## state machine.
##
## Pure VM coverage — no DOM, no TipTap, no HTTP transport. The
## save-flow indirection (``SaveBriefHttpProc``) lets us substitute a
## deterministic stub so the test asserts the VM's reaction to both
## success and failure callbacks without booting a daemon.
##
## Coverage:
##
##   * ``enterEdit`` flips ``mode`` to ``spmEdit`` without disturbing
##     ``markdown`` or ``dirty``.
##   * ``setMarkdown`` flips ``dirty`` to true when the body differs
##     from ``lastSavedMarkdown``; back to false when it matches.
##   * ``cancelEdits`` reverts ``markdown`` to ``lastSavedMarkdown``,
##     clears ``dirty``, and returns ``mode`` to ``spmView``.
##   * ``saveEdits`` with a stub that reports success → updates
##     ``lastSavedMarkdown``, clears ``dirty``, callback observes
##     ``success=true``.
##   * ``saveEdits`` with a stub that reports failure → ``dirty``
##     stays, ``lastSavedMarkdown`` unchanged, callback observes
##     ``success=false``.

import std/unittest

import isonim/core/[signals, computation, owner]
import isonim/editor/views/spec_pane

suite "TBAR-M5 spec pane edit VM":

  test "enter_edit_flips_mode_without_touching_markdown":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Original\n")
      check vm.mode.val == spmView
      check vm.dirty.val == false
      check vm.markdown.val == "# Original\n"
      check vm.lastSavedMarkdown.val == "# Original\n"
      vm.enterEdit()
      check vm.mode.val == spmEdit
      check vm.dirty.val == false
      check vm.markdown.val == "# Original\n"
      dispose()

  test "set_markdown_flips_dirty_when_body_diverges":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Original\n")
      vm.enterEdit()
      check vm.dirty.val == false
      vm.setMarkdown("# Edited\n")
      check vm.dirty.val == true
      # Reverting to the saved body clears ``dirty``.
      vm.setMarkdown("# Original\n")
      check vm.dirty.val == false
      dispose()

  test "cancel_edits_reverts_markdown_and_returns_to_view_mode":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Original\n")
      vm.enterEdit()
      vm.setMarkdown("# Different body\n")
      check vm.dirty.val == true
      vm.cancelEdits()
      check vm.markdown.val == "# Original\n"
      check vm.lastSavedMarkdown.val == "# Original\n"
      check vm.dirty.val == false
      check vm.mode.val == spmView
      dispose()

  test "save_edits_with_success_stub_updates_last_saved_and_clears_dirty":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Original\n")
      vm.enterEdit()
      vm.setMarkdown("# New body\n")
      check vm.dirty.val == true

      var captured: tuple[briefId, markdown: string]
      var observedSuccess: seq[bool] = @[]
      let stub: SaveBriefHttpProc = proc(briefId, markdown: string;
                                         cb: proc(success: bool;
                                                  body: string)) =
        captured = (briefId, markdown)
        cb(true, """{"briefId":"render.fixture","path":"/tmp/x.md","bytesWritten":12}""")
      saveEdits(vm, "render.fixture", "# New body\n", stub,
        proc(success: bool) =
          observedSuccess.add success)
      check captured.briefId == "render.fixture"
      check captured.markdown == "# New body\n"
      check observedSuccess == @[true]
      check vm.lastSavedMarkdown.val == "# New body\n"
      check vm.markdown.val == "# New body\n"
      check vm.dirty.val == false
      dispose()

  test "save_edits_with_failure_stub_keeps_dirty_and_mode":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Original\n")
      vm.enterEdit()
      vm.setMarkdown("# Pending\n")
      check vm.dirty.val == true
      check vm.mode.val == spmEdit

      var observedSuccess: seq[bool] = @[]
      let stub: SaveBriefHttpProc = proc(briefId, markdown: string;
                                         cb: proc(success: bool;
                                                  body: string)) =
        cb(false, "boom")
      saveEdits(vm, "render.fixture", "# Pending\n", stub,
        proc(success: bool) =
          observedSuccess.add success)
      check observedSuccess == @[false]
      check vm.lastSavedMarkdown.val == "# Original\n"
      check vm.markdown.val == "# Pending\n"
      check vm.dirty.val == true
      check vm.mode.val == spmEdit
      dispose()

  test "save_edits_without_http_proc_invokes_callback_with_false":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Original\n")
      vm.enterEdit()
      var observedSuccess: seq[bool] = @[]
      saveEdits(vm, "render.fixture", "# Anything\n", nil,
        proc(success: bool) =
          observedSuccess.add success)
      check observedSuccess == @[false]
      check vm.mode.val == spmEdit
      dispose()
