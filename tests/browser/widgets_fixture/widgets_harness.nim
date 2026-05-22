## TBAR-M2 — browser harness entry-point for the ChoiceGroup widget.
##
## Compiled to JS via ``nim js`` and loaded by
## ``e2e_editor_choice_group_widget.mjs``. Mounts both widget variants
## (segmented + chevron) into pre-existing host containers on the
## page so Playwright can drive them like the real editor would.
##
## The harness intentionally re-uses ``DomRenderer`` from the editor
## (the same renderer the production bundle uses) — there is no
## test-only renderer surface here. The selectors / ARIA / data-attrs
## the test asserts on come from the widget itself, not from harness
## glue.

when not defined(js):
  {.error: "widgets_harness.nim requires the JS backend (nim js)".}

import std/dom
import isonim/core/[owner, computation]
import isonim/editor/dom_renderer
import isonim/editor/views/widgets/choice_group

proc mountHarness*() {.exportc.} =
  ## Mount the two widget variants into ``#segmented-host`` and
  ## ``#chevron-host``. The mounted callbacks set
  ## ``window.__lastSegmentedChange`` / ``window.__lastChevronChange``
  ## so the Playwright test can read the most recently observed
  ## ``onChange`` index.
  let segHost = document.getElementById("segmented-host".cstring)
  let chevHost = document.getElementById("chevron-host".cstring)

  let r = DomRenderer()

  # createRoot owns the reactive graph; harness lives for the
  # lifetime of the page so we never call dispose.
  createRoot do (dispose: proc()):
    let segVm = createSegmentedChoiceVM(
      @["Preview", "Spec"], initialIndex = 0)
    r.mountSegmentedChoice(segHost, segVm, proc(i: int) {.closure.} =
      let payload = i
      {.emit: ["window.__lastSegmentedChange = ", payload, ";"].})

    let chevVm = createChevronChoiceVM(
      @["320x568", "768x1024", "1280x800"], initialIndex = 1)
    r.mountChevronChoice(chevHost, chevVm, proc(i: int) {.closure.} =
      let payload = i
      {.emit: ["window.__lastChevronChange = ", payload, ";"].})

# Run on script load — the page's <body> hosts the two host divs
# already, so we just call mountHarness immediately. The HTML loader
# uses ``defer`` so the body is parsed before this runs.
mountHarness()
