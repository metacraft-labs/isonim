## MockRenderer mounts the genuine production Source/inspector subtree; real
## signals, normalizer, schema ownership and root cleanup run. Authored metadata
## fixtures isolate presentation/admission classification, without substituting
## discovery, compiler/source outcomes, browser geometry or agent transport.
import std/[unittest,tables,strutils,sequtils,options]
import isonim/core/[signals,computation,owner]
import isonim/testing/mock_dom
import isonim/editor/[types,viewmodels,stories]
import isonim/editor/views/shell
proc find(node:MockNode;key,value:string):MockNode =
  if node.attributes.getOrDefault(key)==value:return node
  for child in node.children:
    result=find(child,key,value)
    if result!=nil:return

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

template sourceScopeLabelCases*(renderTree: untyped) =
  suite "Source labels in production inspector trees":
    test "normalized DOM identity is not component ownership; authored local hydration is explicit":
      createRoot do(dispose:proc()):
        let r=MockRenderer();let vm=createEditorVM()
        vm.sidebar.groups.val=buildStoryboard()
        vm.selectedStory.val=StoryRef(group:"TaskRow",name:"Active task",kind:skComponent)
        vm.setEditMode(emEdit)
        let shell=renderTree(r,vm)
        let label=find(shell,"data-source-scope","true");doAssert label!=nil
        var element=domSelection()
        check element.schemaKey=="dom.button"
        vm.inspector.selectedElement.val=element
        check label.textContent=="Unknown"
        check find(shell,"data-inspector-section-row","component-properties").styles.getOrDefault("display")=="none"
        for prop in element.properties.mitems:
          prop.authoredValue=prop.value
        vm.inspector.selectedElement.val=element
        # Computed-only additions have no source span; value hydration alone is
        # incomplete and must not turn the entire selection into a local owner.
        check element.properties.anyIt(it.sourceFile.len == 0)
        check label.textContent=="Unknown"
        # Keep every normalized field. This separate declared ownership fixture
        # maps ALL of them to their story, using the real schema-edge contract;
        # it is not presented as a native discovery/compiler result.
        var schema=DesignSystemSchema()
        for prop in element.properties:
          let key="fixtures.action." & prop.name
          schema.nodes.add DesignSchemaNode(key:key,kind:dsnStoryFixture,property:prop.name)
          schema.sourceOwnership.add DesignSourceOwnership(elementSourceKey:element.id,
            property:prop.name,nodeKey:key)
        vm.designSystemSchema.val=schema
        check vm.inspector.selectedElement.val.properties.len==element.properties.len
        check label.textContent=="Local"
        dispose()

    test "actual scope choices and Source labels agree for native and mapped alias owners":
      createRoot do(dispose:proc()):
        let r=MockRenderer();let vm=createEditorVM()
        vm.sidebar.groups.val=buildStoryboard()
        vm.selectedStory.val=StoryRef(group:"TaskRow",name:"Active task",kind:skComponent)
        vm.setEditMode(emEdit)
        let shell=renderTree(r,vm)
        let label=find(shell,"data-source-scope","true");doAssert label!=nil
        let shared=PropertyInfo(name:"background-color",value:"#112233",authoredValue:"#112233",sourceFile:"styles.nim",
          schemaKey:"classes.native.panel",nativeSourceShared:true,sharedCount:2)
        vm.inspector.selectedElement.val=ElementRef(id:"panel",tag:"div",properties: @[shared])
        let choices=sourceScopeChoices(vm.designSystemSchema.val,vm.inspector.selectedElement.val,shared)
        check choices.anyIt(it.kind==sskSharedClass and it.editable)
        check choices.allIt(it.kind!=sskComponentSchemaApi or not it.editable)
        check label.textContent=="Shared"
        check find(shell,"data-fill-source-scope","true")!=nil
        vm.inspector.selectedElement.val=ElementRef(id:"button",tag:"button",schemaKey:"Button",properties: @[
          PropertyInfo(name:"variant",value:"primary",schemaKey:"Button.variant")])
        check label.textContent=="Unknown"
        vm.designSystemSchema.val=DesignSystemSchema(nodes: @[
          DesignSchemaNode(key:"other",kind:dsnClassDefinition,property:"variant"),
          DesignSchemaNode(key:"Button.variant",kind:dsnComponentVariant,property:"variant")],sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey:"button",property:"variant",nodeKey:"Button.variant",unstructuredViewCode:true)])
        check label.textContent=="Component schema"
        check find(shell,"data-property-row","variant")!=nil
        check find(shell,"data-inspector-section-row","component-properties").styles.getOrDefault("display")=="flex"
        check vm.inspector.pendingSourceEdits.val.len==0
        check vm.chat.messages.val.len==0
        dispose()
