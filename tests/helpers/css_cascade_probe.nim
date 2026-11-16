## Driver for `tests/test_editor_css_cascade_chromium.mjs`: the real
## `css_patch` writer over JSON cases, in two steps.
##
##   css_cascade_probe conditions <cases.json> <out.json>
##     -> [[prelude, ...], ...]: each case's `editConditions`, the conditions
##        the preview is asked about.
##   css_cascade_probe patch <cases.json> <answers.json> <out.json>
##     -> [{found, undecided, condition, ok, outcome, content, message}, ...]:
##        `editTargetAtWidth` and `patchCssDeclarationAt` with the preview's
##        answers ({prelude: bool} per case).
import std/[json, os]
import isonim/editor/css_patch

let mode = paramStr(1)
let cases = parseFile(paramStr(2))
var output = newJArray()
if mode == "conditions":
  for c in cases:
    output.add %c["css"].getStr().editConditions(c["selector"].getStr(),
      c["property"].getStr())
  writeFile(paramStr(3), $output)
else:
  let answers = parseFile(paramStr(3))
  for index, c in cases.getElems():
    var given: seq[CssConditionAnswer] = @[]
    for condition, holds in answers[index]:
      given.add CssConditionAnswer(condition: condition, holds: holds.getBool())
    let css = c["css"].getStr()
    let target = css.editTargetAtWidth(c["selector"].getStr(),
      c["property"].getStr(), c["width"].getInt(), given)
    let patched = patchCssDeclarationAt(css, c["selector"].getStr(),
      c["property"].getStr(), c["value"].getStr(), c["width"].getInt(), given)
    output.add %*{"found": target.found, "undecided": target.undecided,
      "condition": target.condition, "ok": patched.ok,
      "outcome": $patched.outcome, "content": patched.content,
      "message": patched.message}
  writeFile(paramStr(4), $output)
