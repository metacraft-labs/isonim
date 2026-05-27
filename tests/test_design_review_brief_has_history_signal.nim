## REV-M8 — briefHasHistory signal tests.
##
## The signal is owned by the ``DesignReviewState`` glue (see
## ``isonim/editor/views/design_review_mount.nim``).  The poll is
## triggered by changes to the active story / backend; this test
## checks the signal updates in response to direct VM writes and
## (when the daemon URL resolves) drives one HTTP round trip against
## a real daemon.
##
## We don't need a full editor here — the relevant surface is the
## ``DesignReviewState`` lazily allocated per-EditorVM.

import std/[unittest, options, strutils]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/design_review_mount

suite "REV-M8 briefHasHistory signal":

  test "test_brief_has_history_initially_false":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      check st.briefHasHistory.val == false
      dispose()

  test "test_brief_id_tracks_selected_story":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      check st.briefId.val.len == 0
      # TBAR-M1: ``resolveBriefId`` projects the (story, backend) pair
      # through ``builtInBriefIndex().byPreview`` rather than hand-
      # rolling ``story.group + "/" + story.name``. We use the
      # canonical story the bundled ``render.task-app`` brief covers
      # (``briefs/render/task-app.md``: ``storyRef: { group:
      # "Task App / Pages", name: "Inbox", kind: page, index: 0 }``)
      # so the lookup resolves to the real briefId baked into the
      # static index.
      let s = StoryRef(group: "Task App / Pages", name: "Inbox",
                       kind: skPage, index: 0)
      vm.selectedStory.val = s
      # The reactive effect runs synchronously when the signal is
      # written under the same root.
      check st.briefId.val.len > 0
      check "render" in st.briefId.val
      dispose()

  test "test_brief_has_history_false_when_no_daemon":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      # No http client configured (or one that points at an unreachable
      # daemon) → the poll silently leaves ``briefHasHistory`` at
      # false; the 🕘 button stays hidden.
      st.briefId.val = "render.x"
      pollBriefHasHistory(st)
      check st.briefHasHistory.val == false
      dispose()

  test "test_history_button_vm_mirrors_signal":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      st.briefHasHistory.val = true
      # The render-effect installed in ensureDesignReviewState mirrors
      # the signal onto the HistoryButtonVM the chrome bar binds to.
      check st.historyVm.briefHasHistory.val == true
      st.briefHasHistory.val = false
      check st.historyVm.briefHasHistory.val == false
      dispose()
