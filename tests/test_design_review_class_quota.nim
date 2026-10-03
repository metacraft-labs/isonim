## Production context-budget tests with the real compiled Tailwind inventory.
## No compiler, ViewModel, compactor or codec is mocked. Repeated diagnostics and
## prior-admitted snapshots are controlled protocol input. The HTTP suite also
## runs this file against a real Tailwind extract with more than 128 classes.
import std/[algorithm, json, options, os, strutils, tables, unittest, unicode]
import isonim/dsl/tailwind
import isonim/editor/design_review/context_budget
import isonim/editor/design_review/context_policy

proc compiledClasses(): JsonNode =
  var names: seq[string]
  for name in tailwindStyles.keys: names.add name
  names.sort()
  result = %names

proc snapshot(classes: JsonNode): JsonNode =
  result = %* {"availableTailwindClasses":classes, "diagnostics":[], "contextAvailability":[],
    "accumulatedEdits":["  exact 保持😀  "], "pendingSourceEdits":[{"newValue":"  exact 保持😀  "}],
    "designSystemConstraints":["unchanged"], "currentFileDiffs":["exact diff"],
    "selectedStory":{"group":"Hero","name":"current","kind":0,"index":0},
    "selectedElement":{"id":"target","sourceKey":"source","domPath":"main", "schemaKey":"key",
      "tag":"main","sourceFile":"catalog.nim","sourceLine":2,"sourceColumn":1,
      "properties":[],"children":[],"ancestors":[],"ancestorIds":[],"depth":0}}
  if classes.len > 128:
    result["contextAvailability"].add %compiledClassMinimumMarker(classes.len)
  for i in 0 .. 2:
    result["diagnostics"].add(%* {"source":"compiler","category":"same",
      "message":"actionable 保持😀 " & repeat("x",450),"index":i})

proc minimum(context: JsonNode): JsonNode =
  result = parseJson($context)
  result["diagnostics"] = %* [context["diagnostics"][0]]
  result["contextAvailability"].add %"diagnostics: 1/3 records; quota truncated"

suite "compiled class quota minimum":
  test "real inventory survives removable diagnostics at exact Unicode wire quota":
    let classes = compiledClasses()
    check classes.len > 1
    if getEnv("ISONIM_TEST_LARGE_COMPILED_CLASSES") == "1": check classes.len > 128
    let context = snapshot(classes)
    let before = $context
    let feasible = minimum(context)
    let cap = runeLen($feasible)
    check cap < runeLen($context)
    let bounded = compactEditorContext(context,cap)
    check bounded.isSome
    if bounded.isSome:
      check bounded.get == feasible
      check bounded.get["availableTailwindClasses"] == classes
      check runeLen($referenceContext(bounded.get,nil,nil)) == cap
      check ($bounded.get).len > cap # UTF-8 bytes are not Unicode quota units
      check $context == before
    check compactEditorContext(context,cap-1).isNone
    check $context == before
  test "changed prior admitted inventory and relevance order retain every current class":
    let classes = compiledClasses()
    check classes.len > 1
    let context = snapshot(classes)
    var prior = parseJson($context)
    prior["availableTailwindClasses"].elems.setLen(classes.len-1)
    prior["diagnostics"] = newJArray()
    # A compiled class added after the previous admitted build cannot disappear.
    let feasible = minimum(context)
    let cap = runeLen($referenceContext(feasible,prior,nil))
    let bounded = compactEditorContext(context,cap,prior)
    check bounded.isSome
    if bounded.isSome:
      let wire = referenceContext(bounded.get,prior,nil)
      check runeLen($wire) <= cap
      check deliveredContext(wire,prior,context) == feasible
      check bounded.get["availableTailwindClasses"] == classes
    check compactEditorContext(context,cap-1,prior).isNone
    # The selected/edited/preview producer orders current relevance first.
    var reordered = parseJson($context)
    reordered["availableTailwindClasses"] = newJArray()
    reordered["availableTailwindClasses"].add classes[classes.len-1]
    for i in 0 ..< classes.len-1: reordered["availableTailwindClasses"].add classes[i]
    for entry in reordered["diagnostics"]:
      entry["message"] = %("changed current " & entry["message"].getStr())
    let reorderedMinimum = minimum(reordered)
    let reorderedCap = runeLen($referenceContext(reorderedMinimum,context,nil))
    let changed = compactEditorContext(reordered,reorderedCap,context)
    check changed.isSome
    if changed.isSome:
      let wire = referenceContext(changed.get,context,nil)
      check runeLen($wire) <= reorderedCap
      check deliveredContext(wire,context,reordered) == reorderedMinimum
      check changed.get["availableTailwindClasses"] == reordered["availableTailwindClasses"]
    check $context == $snapshot(classes)
  test "extras above stable minimum remain optional unless producer declares larger relevance":
    let classes = compiledClasses()
    var context = snapshot(classes)
    context["contextAvailability"] = newJArray() # no larger relevance declaration
    var feasible = minimum(context)
    if classes.len > 128:
      feasible["availableTailwindClasses"].elems.setLen(128)
      feasible["contextAvailability"].add %("availableTailwindClasses: 128/" & $classes.len & " records; quota truncated")
    let cap = runeLen($feasible)
    let bounded = compactEditorContext(context,cap)
    check bounded.isSome
    if bounded.isSome:
      check bounded.get["availableTailwindClasses"].len >= min(128,classes.len)
      for i in 0 ..< min(128,classes.len): check bounded.get["availableTailwindClasses"][i] == classes[i]
      check runeLen($bounded.get) <= cap
    if classes.len > 128:
      if bounded.isSome: check bounded.get["availableTailwindClasses"].len == 128
      context["contextAvailability"].add %compiledClassMinimumMarker(classes.len)
      check compactEditorContext(context,cap).isNone
  test "producer minimum declarations reject malformed conflicting and unavailable claims":
    let classes = compiledClasses()
    for marker in [compiledClassMinimumMarker(classes.len+1), compiledClassMinimumMarker(128),
        CompiledClassMinimumPrefix & "000129" & CompiledClassMinimumSuffix,
        CompiledClassMinimumPrefix & "129x" & CompiledClassMinimumSuffix,
        CompiledClassMinimumPrefix & repeat("9",100) & CompiledClassMinimumSuffix,
        "availableTailwindClasses: required minimum malformed",
        "availableTailwindClasses: required minimum truncated",
        "availableTailwindClasses: required minimum budget"]:
      var context = snapshot(classes)
      context["contextAvailability"] = %* [marker]
      check compactEditorContext(context,100000).isNone
    if classes.len > 129:
      var context = snapshot(classes)
      context["contextAvailability"].add %compiledClassMinimumMarker(classes.len-1)
      check compactEditorContext(context,100000).isNone
      context["contextAvailability"] = %* [compiledClassMinimumMarker(classes.len), compiledClassMinimumMarker(classes.len)]
      check compactEditorContext(context,100000).isSome # identical declarations deduplicate
    check compactEditorContext(%* {"contextAvailability":[compiledClassMinimumMarker(129)]},100000).isNone
    check compactEditorContext(%* {"contextAvailability":["availableTailwindClasses: required minimum budget"]},100000).isNone
    var context = snapshot(classes)
    context["contextAvailability"].add %"sourceMap: unavailable (normal producer explanation)"
    let result = compactEditorContext(context,100000)
    check result.isSome
    if result.isSome: check %"sourceMap: unavailable (normal producer explanation)" in result.get["contextAvailability"].elems
