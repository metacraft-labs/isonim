## CHRM-M4 — headless ViewModel test for the spec-pane formatting
## toolbar.
##
## Pure VM coverage — no DOM, no TipTap.  The toolbar's mount-side
## wiring (``onSelectionUpdate`` / ``onTransaction`` subscriptions)
## is exercised by the browser e2e test; the VM tests below cover
## the reactive-signal contract every variant of the mount depends
## on.
##
## Coverage:
##
##   * ``createSpecEditorToolbarVM`` returns sensible defaults.
##   * ``setActiveMarks`` writes the active inline-mark set.
##   * ``setActiveBlockKind`` writes the active block kind.
##   * ``setCanUndo`` / ``setCanRedo`` track history availability.
##   * Subscribers see signal changes.
##   * ``openLinkDraft`` / ``closeLinkDraft`` flip the URL popover
##     state.

import std/[unittest, sets]

import isonim/core/[signals, computation, owner]
import isonim/editor/views/spec_editor_toolbar

suite "CHRM-M4 spec editor toolbar VM":

  test "create_returns_defaults":
    createRoot do (dispose: proc()):
      let vm = createSpecEditorToolbarVM()
      check vm.activeMarks.val.len == 0
      check vm.activeBlockKind.val == btParagraph
      check vm.canUndo.val == false
      check vm.canRedo.val == false
      check vm.linkDraftOpen.val == false
      check vm.linkDraftHref.val == ""
      dispose()

  test "set_active_marks_updates_signal":
    createRoot do (dispose: proc()):
      let vm = createSpecEditorToolbarVM()
      var marks = initHashSet[FormattingMark]()
      marks.incl fmBold
      marks.incl fmItalic
      vm.setActiveMarks(marks)
      check fmBold in vm.activeMarks.val
      check fmItalic in vm.activeMarks.val
      check fmStrike notin vm.activeMarks.val
      check vm.activeMarks.val.len == 2
      dispose()

  test "set_active_block_kind_updates_signal":
    createRoot do (dispose: proc()):
      let vm = createSpecEditorToolbarVM()
      vm.setActiveBlockKind(btHeading2)
      check vm.activeBlockKind.val == btHeading2
      vm.setActiveBlockKind(btBlockquote)
      check vm.activeBlockKind.val == btBlockquote
      vm.setActiveBlockKind(btParagraph)
      check vm.activeBlockKind.val == btParagraph
      dispose()

  test "set_can_undo_redo_updates_signals":
    createRoot do (dispose: proc()):
      let vm = createSpecEditorToolbarVM()
      vm.setCanUndo(true)
      vm.setCanRedo(true)
      check vm.canUndo.val == true
      check vm.canRedo.val == true
      vm.setCanUndo(false)
      check vm.canUndo.val == false
      check vm.canRedo.val == true
      dispose()

  test "subscribers_fire_when_signals_change":
    createRoot do (dispose: proc()):
      let vm = createSpecEditorToolbarVM()
      var marksObservations: seq[int] = @[]
      var blockObservations: seq[BlockKind] = @[]
      var undoObservations: seq[bool] = @[]

      createRenderEffect proc() =
        marksObservations.add vm.activeMarks.val.len
      createRenderEffect proc() =
        blockObservations.add vm.activeBlockKind.val
      createRenderEffect proc() =
        undoObservations.add vm.canUndo.val

      # Initial reactive runs.
      check marksObservations == @[0]
      check blockObservations == @[btParagraph]
      check undoObservations == @[false]

      var marks = initHashSet[FormattingMark]()
      marks.incl fmBold
      vm.setActiveMarks(marks)
      vm.setActiveBlockKind(btHeading1)
      vm.setCanUndo(true)

      check marksObservations[^1] == 1
      check blockObservations[^1] == btHeading1
      check undoObservations[^1] == true
      dispose()

  test "open_close_link_draft_flips_signals":
    createRoot do (dispose: proc()):
      let vm = createSpecEditorToolbarVM()
      check vm.linkDraftOpen.val == false
      vm.openLinkDraft("https://example.com")
      check vm.linkDraftOpen.val == true
      check vm.linkDraftHref.val == "https://example.com"
      vm.closeLinkDraft()
      check vm.linkDraftOpen.val == false
      check vm.linkDraftHref.val == ""
      dispose()

  test "collect_active_marks_returns_empty_on_nil_editor":
    # Native build: ``editor`` is a ``ref object`` with nil default.
    # ``collectActiveMarks`` should return an empty set rather than
    # crash.
    createRoot do (dispose: proc()):
      let marks = collectActiveMarks(nil)
      check marks.len == 0
      dispose()

  test "current_block_kind_returns_paragraph_on_nil_editor":
    createRoot do (dispose: proc()):
      check currentBlockKind(nil) == btParagraph
      dispose()
