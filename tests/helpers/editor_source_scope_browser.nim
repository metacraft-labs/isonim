## Real DOMRenderer production inspector Source presentation acceptance. The production
## normalizer and schema resolver run. Explicit metadata fixtures define known
## ownership solely to test presentation; no native discovery, filesystem,
## compiler, source ACK or Harbor result is simulated or claimed.
import std/[options,json,dom]
import isonim/editor/[browser,viewmodels,types,stories]
import isonim/core/[signals,computation,owner]
import isonim/editor/dom_renderer
import isonim/editor/views/shell
proc domSelection(testId = ""; className = ""; declared = ""): ElementRef =
  # The real normalizer consumes the production preview payload format. Its
  # generated DOM identity is preserved, not erased to fake absence of schema.
  previewDomElementRef(StoryRenderMetadata(sourceFile:"stories.nim",sourceLine:1),
    tag="button",testId=testId,className=className,role="",elementPath="button",ancestry="",
    sourceFile="stories.nim",sourceLine=1,display="inline-flex",position="static",
    backgroundColor="rgb(17, 34, 51)",color="rgb(255, 255, 255)",padding="8px",
    margin="0px",width="120px",height="48px",borderRadius="4px",borderWidth="0px",
    borderStyle="none",borderColor="rgb(0, 0, 0)",fontSize="16px",fontWeight="400",
    lineHeight="normal",boxShadow="none",opacity="1",rectWidth="120",rectHeight="48",
    textContent="Continue",elementId="action",sourceKey="",schemaKey=declared,
    ancestorIds="",layerTreeJson="",computedStyles="padding-top=16px;flex-direction=row")

let editor=createEditorVM()
editor.sidebar.groups.val=buildStoryboard()
editor.selectedStory.val=StoryRef(group:"TaskRow",name:"Active task",kind:skComponent)
editor.setEditMode(emEdit)
injectEditorStyles()
createRoot do(dispose:proc()):
  document.body.appendChild(renderInspectorPanel[DomRenderer,Element](DomRenderer(),editor))
proc stage(n:int) =
  case n
  of 0:
    editor.designSystemSchema.val=DesignSystemSchema()
    editor.inspector.selectedElement.val=domSelection()
  of 1:
    var element=editor.inspector.selectedElement.val
    for prop in element.properties.mitems:prop.authoredValue=prop.value
    editor.inspector.selectedElement.val=element
  of 2:
    let element=editor.inspector.selectedElement.val
    var schema=DesignSystemSchema()
    for prop in element.properties:
      let key="fixtures.action." & prop.name
      schema.nodes.add DesignSchemaNode(key:key,kind:dsnStoryFixture,property:prop.name)
      schema.sourceOwnership.add DesignSourceOwnership(elementSourceKey:element.id,property:prop.name,nodeKey:key)
    editor.designSystemSchema.val=schema
  of 3:
    editor.designSystemSchema.val=DesignSystemSchema()
    editor.inspector.selectedElement.val=ElementRef(id:"panel",tag:"div",properties: @[
      PropertyInfo(name:"background-color",value:"#112233",authoredValue:"#112233",sourceFile:"styles.nim",
        schemaKey:"classes.native.panel",nativeSourceShared:true,sharedCount:2)])
  of 4:
    editor.inspector.selectedElement.val=ElementRef(id:"button",tag:"button",schemaKey:"Button",properties: @[
      PropertyInfo(name:"variant",value:"primary",schemaKey:"Button.variant")])
  of 5:
    editor.designSystemSchema.val=DesignSystemSchema(nodes: @[
      DesignSchemaNode(key:"other",kind:dsnClassDefinition,property:"variant"),
      DesignSchemaNode(key:"Button.variant",kind:dsnComponentVariant,property:"variant")],sourceOwnership: @[
      DesignSourceOwnership(elementSourceKey:"button",property:"variant",nodeKey:"Button.variant",unstructuredViewCode:true)])
  of 6..11:
    let local=DesignSourceOwnership(elementSourceKey:"ambiguous",property:"variant",nodeKey:"local")
    let component=DesignSourceOwnership(elementSourceKey:"ambiguous",property:"variant",nodeKey:"Button.variant",unstructuredViewCode:true)
    let other=DesignSourceOwnership(elementSourceKey:"ambiguous",property:"variant",nodeKey:"local.other")
    let edges = case n
      of 6: @[local]
      of 7: @[component]
      of 8: @[local,component]
      of 9: @[component,local]
      of 10: @[local,other]
      else: @[local,local]
    editor.inspector.selectedElement.val=ElementRef(id:"ambiguous",tag:"button",schemaKey:"Button",properties: @[
      PropertyInfo(name:"variant",value:"primary",schemaKey:"Button.variant")])
    editor.designSystemSchema.val=DesignSystemSchema(nodes: @[
      DesignSchemaNode(key:"local",kind:dsnStoryFixture,property:"variant"),
      DesignSchemaNode(key:"local.other",kind:dsnStoryFixture,property:"variant"),
      DesignSchemaNode(key:"Button.variant",kind:dsnComponentVariant,property:"variant")],sourceOwnership:edges)
  of 12..14:
    editor.inspector.selectedElement.val=ElementRef(id:"path-target",tag:"button",schemaKey:"Button",
      domPath:(if n==12:"/actual" elif n==13:"/different" else:""),properties: @[
        PropertyInfo(name:"variant",value:"primary",schemaKey:"Button.variant")])
    editor.designSystemSchema.val=DesignSystemSchema(nodes: @[
      DesignSchemaNode(key:"Button.variant",kind:dsnComponentVariant,property:"variant")],sourceOwnership: @[
      DesignSourceOwnership(property:"variant",nodeKey:"Button.variant",domPath:"/actual",unstructuredViewCode:true)])
  else:discard
proc state():cstring =
  let element=editor.inspector.selectedElement.val
  var unknownFile=0
  for prop in element.properties:
    if prop.sourceFile.len==0:inc unknownFile
  var sharedAllowed=false
  var apiAllowed=false
  if element.properties.len>0:
    for choice in sourceScopeChoices(editor.designSystemSchema.val,element,element.properties[0]):
      if choice.kind==sskSharedClass and choice.editable:sharedAllowed=true
      if choice.kind==sskComponentSchemaApi and choice.editable:apiAllowed=true
  cstring($(%*{"key":element.schemaKey,"properties":element.properties.len,"unmappedFiles":unknownFile,
    "sharedAllowed":sharedAllowed,"apiAllowed":apiAllowed,"pending":editor.inspector.pendingSourceEdits.val.len,
    "messages":editor.chat.messages.val.len}))
{.emit:["window.__sourceLabels={stage:",stage,",state:",state,"};"].}
