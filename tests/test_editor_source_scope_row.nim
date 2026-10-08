## MockRenderer is used only for portable widget lifecycle/option event wiring.
## It claims no DOM geometry, source write or compiler success. Actual shared
## ownership/source/compiler/preview is tested by test_editor_source_style_gui.mjs.
import std/[unittest, tables, sequtils]
import isonim/core/[signals, owner, computation]
import isonim/editor/views/choice_row
import isonim/testing/mock_dom
import isonim/editor/[types, viewmodels]

proc find(node:MockNode; label:string):MockNode =
  if node.attributes.getOrDefault("aria-label") == label: return node
  for child in node.children:
    result = find(child,label)
    if result != nil: return

suite "Reactive horizontal source scopes":
  test "verified zero-line native declarations expose only their mapped scope":
    let element=ElementRef(id:"hero",tag:"section")
    let schema=DesignSystemSchema()
    let mapped=PropertyInfo(name:"padding-top",value:"48px",authoredValue:"48px",
      sourceFile:"styles.nim",schemaKey:"classes.native.hero",nativeSourceShared:true,sharedCount:2)
    let choices=sourceScopeChoices(schema,element,mapped)
    check choices.anyIt(it.kind==sskSharedClass and it.editable and it.sourceLine==0 and it.schemaKey==mapped.schemaKey)
    check choices.anyIt(it.kind==sskLocalInstance and not it.editable)
    for malformed in [PropertyInfo(name:"padding-top",nativeSourceShared:true),
        PropertyInfo(name:"padding-top",nativeSourceShared:true,sourceFile:"styles.nim",schemaKey:"classes.native.hero"),
        PropertyInfo(name:"padding-top",nativeSourceShared:true,authoredValue:"48px",schemaKey:"classes.native.hero"),
        PropertyInfo(name:"padding-top",nativeSourceShared:true,authoredValue:"48px",sourceFile:"styles.nim",schemaKey:"legacy.hero"),
        PropertyInfo(name:"padding-top",nativeSourceShared:true,authoredValue:"48px",sourceFile:"styles.nim",schemaKey:"tokens.native.hero"),
        PropertyInfo(name:"padding-top",authoredValue:"48px",sourceFile:"styles.nim",schemaKey:"classes.native.hero")]:
      check sourceScopeChoices(schema,element,malformed).allIt(not it.editable)
    let token=PropertyInfo(name:"background-color",authoredValue:"#fbfbfc",sourceFile:"styles.nim",
      schemaKey:"tokens.native.panel",tokenName:"--panel",nativeSourceShared:true,nativeSourceToken:true,sharedCount:40)
    let tokenChoices=sourceScopeChoices(schema,element,token)
    check tokenChoices.anyIt(it.kind==sskSemanticToken and it.editable and it.riskLevel==ssrHigh)
    check tokenChoices.allIt(it.kind!=sskSharedClass or not it.editable)
    var missingName=token
    missingName.tokenName=""
    check sourceScopeChoices(schema,element,missingName).allIt(not it.editable)

  test "empty mount hydrates scopes and disposes obsolete callbacks":
    createRoot(proc(dispose:proc()) =
      let r=MockRenderer()
      let options=createSignal[seq[CompactChoiceOption]](@[])
      var calls:seq[string]
      let strip=renderCompactChoiceRow[MockRenderer,MockNode](r,"","Source scope",proc():seq[CompactChoiceOption]=options.val,visibleLimit=1)
      check strip.root.children.len == 1
      options.val = @[
        CompactChoiceOption(label:"Local",shortLabel:"Loc",ariaLabel:"Local scope",enabled:false),
        CompactChoiceOption(label:"Shared40",shortLabel:"Cls40",ariaLabel:"Shared scope",enabled:true,selected:true,
          dataAttrs: @[("target","first")], onChoose:proc()=calls.add "first")]
      let original=find(strip.root,"Shared scope")
      check original != nil
      check original.attributes["aria-pressed"] == "true"
      original.fireEvent("click")
      check calls.len == 1
      doAssert calls.len == 1
      let count=calls.len
      options.val = @[
        CompactChoiceOption(label:"Local",shortLabel:"Loc",ariaLabel:"Local scope",enabled:true,selected:true,
          dataAttrs: @[("target","second")], onChoose:proc()=calls.add "second"),
        CompactChoiceOption(label:"Shared40",shortLabel:"Cls40",ariaLabel:"Shared scope",enabled:false)]
      original.fireEvent("click")
      check calls.len == count
      let local=find(strip.root,"Local scope")
      check local.attributes["data-compact-choice-enabled"] == "true"
      local.fireEvent("click")
      check calls[^1] == "second"
      let after=calls.len
      dispose()
      local.fireEvent("click")
      check calls.len == after
      doAssert calls.len == after)
