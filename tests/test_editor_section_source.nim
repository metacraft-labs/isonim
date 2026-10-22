## MockRenderer isolates the real Source view signals, provenance classification
## and owner cleanup. Authored schema/native metadata fixtures test presentation;
## no discovery, native filesystem/compiler result or agent outcome is mocked.
## Actual source transactions are covered by the registered native/GUI suites.
## Phase G — section_source widget unit test.

import std/[options, sequtils, strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_source
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_source":

  test "mounts file / scope / staged / ownership rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-source-section-body", "true") != nil
      check findByAttr(root, "data-source-file-line", "true") != nil
      check findByAttr(root, "data-source-scope", "true") != nil
      check findByAttr(root, "data-source-staged-count", "true") != nil
      check findByAttr(root, "data-source-ownership", "true") != nil
      dispose()

  test "file:line reflects the selected element":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        sourceFile: "src/views/home.nim", sourceLine: 42)
      let fl = findByAttr(root, "data-source-file-line", "true")
      check fl != nil
      check fl.textContent == "src/views/home.nim:42"

      let scope = findByAttr(root, "data-source-scope", "true")
      check scope != nil
      check scope.textContent == "Unknown"
      dispose()

  test "ownership warning surfaces when conflicts exist":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)

      let ownership = findByAttr(root, "data-source-ownership", "true")
      check ownership != nil
      check ownership.textContent == "No conflicts"
      check ownership.attributes.getOrDefault(
        "data-source-ownership-warning") == "false"

      vm.inspector.conflicts.val = @[CSSSourceConflict(),
        CSSSourceConflict()]
      check ownership.textContent == "2 conflict(s)"
      check ownership.attributes.getOrDefault(
        "data-source-ownership-warning") == "true"
      dispose()


  test "mapped readonly owners and style API agree with shared scope semantics":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)
      let scope = findByAttr(root,"data-source-scope","true")
      vm.inspector.selectedElement.val = ElementRef(id:"button",tag:"button",
        properties: @[PropertyInfo(name:"variant",value:"primary",schemaKey:"legacy.Button.variant")])
      for pair in [(dsnComponentVariant,"Component schema"),(dsnStyleDefinition,"Component schema"),
          (dsnClassDefinition,"Shared"),(dsnSemanticToken,"Theme token"),(dsnStoryFixture,"Local")]:
        vm.designSystemSchema.val = DesignSystemSchema(nodes: @[
          DesignSchemaNode(key:"owner",kind:pair[0],property:"variant")],sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey:"button",property:"variant",nodeKey:"owner",unstructuredViewCode:true)])
        let mapped = resolveDesignSourceOwnership(vm.designSystemSchema.val,vm.inspector.selectedElement.val,"variant")
        check not mapped.ok
        check mapped.nodeKey == "owner"
        check scope.textContent == pair[1]
      check sourceScopeKindForNode(dsnStyleDefinition) == sskComponentSchemaApi
      dispose()

  test "uncertain rewrite destinations and unrelated nodes do not invent ownership":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r,root,vm)
      let scope=findByAttr(root,"data-source-scope","true")
      vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[
        PropertyInfo(name:"padding",value:"4px",schemaKey:"arbitrary",sharedCount:12)])
      vm.designSystemSchema.val=DesignSystemSchema(nodes: @[
        DesignSchemaNode(key:"unrelated",kind:dsnStyleDefinition,property:"padding")])
      check scope.textContent == "Unknown"
      for rewrite in [0,1]:
        vm.designSystemSchema.val=DesignSystemSchema(nodes: @[
          DesignSchemaNode(key:"owner",kind:dsnStyleDefinition,property:"padding")],sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey:"target",property:"padding",nodeKey:"owner",
            fallbackAllowed:rewrite==0,tailwindUtilities:if rewrite==1: @["p-4"] else: @[])])
        check scope.textContent == "Unknown"
      dispose()

  test "native declaration domains aggregate without counting guesses or permissions":
    createRoot do (dispose: proc()):
      let r=MockRenderer()
      let root=r.createElement("div")
      let vm=createEditorVM()
      mountSectionSource[MockRenderer,MockNode](r,root,vm)
      let scope=findByAttr(root,"data-source-scope","true")
      let local=PropertyInfo(name:"width",value:"120px",origin:poSetStyle,sourceFile:"story.nim",directStyleAllowed:false)
      let shared=PropertyInfo(name:"padding",value:"4px",authoredValue:"4px",sourceFile:"styles.nim",
        schemaKey:"classes.native.panel",nativeSourceShared:true,sharedCount:12)
      let token=PropertyInfo(name:"color",value:"#112233",authoredValue:"#112233",sourceFile:"styles.nim",
        schemaKey:"tokens.native.ink",nativeSourceShared:true,nativeSourceToken:true,tokenName:"--ink",sharedCount:12)
      vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[local])
      check scope.textContent=="Local"
      vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[shared])
      check scope.textContent=="Shared"
      vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[token])
      check scope.textContent=="Theme token"
      vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[shared,local,token])
      check scope.textContent=="Mixed"
      var permission=vm.workspacePermissions.val
      permission.writeSource=false
      vm.workspacePermissions.val=permission
      check scope.textContent=="Mixed"
      vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[shared,PropertyInfo(name:"opacity",value:"1")])
      check scope.textContent=="Unknown"
      for prop in [PropertyInfo(name:"padding",sharedCount:99),PropertyInfo(name:"padding",schemaKey:"Button.padding"),
          PropertyInfo(name:"padding",nativeSourceShared:true,schemaKey:"classes.native.panel"),
          PropertyInfo(name:"padding",sourceFile:"styles.nim",authoredValue:"4px",nativeSourceShared:true,schemaKey:"tokens.native.panel")]:
        vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[prop])
        check scope.textContent=="Unknown"
      dispose()

  test "all matching owner destinations must agree independent of edge order":
    createRoot do(dispose:proc()):
      let r=MockRenderer();let root=r.createElement("div");let vm=createEditorVM()
      mountSectionSource[MockRenderer,MockNode](r,root,vm)
      let scope=findByAttr(root,"data-source-scope","true")
      let prop=PropertyInfo(name:"width",value:"120px")
      let element=ElementRef(id:"target",tag:"div",properties: @[prop])
      vm.inspector.selectedElement.val=element
      let local=DesignSourceOwnership(elementSourceKey:"target",property:"width",nodeKey:"local")
      let component=DesignSourceOwnership(elementSourceKey:"target",property:"width",nodeKey:"component",unstructuredViewCode:true)
      let nodes = @[DesignSchemaNode(key:"local",kind:dsnStoryFixture,property:"width"),
        DesignSchemaNode(key:"component",kind:dsnComponentVariant,property:"width"),
        DesignSchemaNode(key:"local.other",kind:dsnStoryFixture,property:"width")]
      var writableComponent=component;writableComponent.unstructuredViewCode=false
      for edges in [@[local],@[local,local],@[component],@[component,component],@[component,writableComponent]]:
        vm.designSystemSchema.val=DesignSystemSchema(nodes:nodes,sourceOwnership:edges)
        check not designSourceOwnershipIsAmbiguous(vm.designSystemSchema.val,element,prop)
        check scope.textContent == (if edges[0].nodeKey=="local":"Local" else:"Component schema")
      var differentLocal=local;differentLocal.nodeKey="local.other"
      var differentDestination=local;differentDestination.sourceSpan=SourceSpan(file:"other.nim",line:2)
      var missing=local;missing.nodeKey="missing"
      var invalid=local;invalid.nodeKey=""
      for extra in [component,differentLocal,differentDestination,missing,invalid]:
        for edges in [@[local,extra],@[extra,local]]:
          vm.designSystemSchema.val=DesignSystemSchema(nodes:nodes,sourceOwnership:edges)
          check designSourceOwnershipIsAmbiguous(vm.designSystemSchema.val,element,prop)
          check scope.textContent=="Unknown"
      # The original writer still resolves its first matching edge; this fix is
      # presentation-only and cannot silently redesign its admission semantics.
      vm.designSystemSchema.val=DesignSystemSchema(nodes:nodes,sourceOwnership: @[local,component])
      check resolveDesignSourceOwnership(vm.designSystemSchema.val,element,"width").nodeKey=="local"
      dispose()

  test "complete native mapping and matched graph owner must describe the same destination":
    createRoot do(dispose:proc()):
      let r=MockRenderer();let root=r.createElement("div");let vm=createEditorVM()
      mountSectionSource[MockRenderer,MockNode](r,root,vm)
      let scope=findByAttr(root,"data-source-scope","true")
      for token in [false,true]:
        let key=if token:"tokens.native.ink" else:"classes.native.panel"
        let prop=PropertyInfo(name:"color",value:"#112233",authoredValue:"#112233",sourceFile:"styles.nim",
          schemaKey:key,nativeSourceShared:true,nativeSourceToken:token,tokenName:if token:"--ink" else:"")
        vm.inspector.selectedElement.val=ElementRef(id:"target",tag:"div",properties: @[prop])
        let kind=if token:dsnSemanticToken else:dsnClassDefinition
        let node=DesignSchemaNode(key:key,kind:kind,property:"color",sourceSpan:SourceSpan(file:"styles.nim",line:1))
        let edge=DesignSourceOwnership(elementSourceKey:"target",property:"color",nodeKey:key,unstructuredViewCode:true)
        vm.designSystemSchema.val=DesignSystemSchema(nodes: @[node],sourceOwnership: @[edge])
        check scope.textContent==(if token:"Theme token" else:"Shared")
        for conflict in [0,1,2]:
          var other=node;var owned=edge
          if conflict==0:other.key="different";owned.nodeKey="different"
          elif conflict==1:other.sourceSpan.file="different.nim"
          else:other.kind=dsnStoryFixture
          vm.designSystemSchema.val=DesignSystemSchema(nodes: @[other],sourceOwnership: @[owned])
          check scope.textContent=="Unknown"
      dispose()

  test "required ownership selectors must be known before Source asserts their owner":
    createRoot do(dispose:proc()):
      let r=MockRenderer();let root=r.createElement("div");let vm=createEditorVM()
      mountSectionSource[MockRenderer,MockNode](r,root,vm)
      let scope=findByAttr(root,"data-source-scope","true")
      let prop=PropertyInfo(name:"variant",value:"primary",schemaKey:"Button.variant")
      var element=ElementRef(id:"button",sourceKey:"button-source",schemaKey:"Button",tag:"button",properties: @[prop])
      let node=DesignSchemaNode(key:"owner",kind:dsnComponentVariant,property:"variant")
      let bySource=DesignSourceOwnership(property:"variant",nodeKey:"owner",elementSourceKey:"button-source",unstructuredViewCode:true)
      let byPropertyAlias=DesignSourceOwnership(property:"variant",nodeKey:"owner",schemaKey:"Button.variant",unstructuredViewCode:true)
      let byElementAlias=DesignSourceOwnership(property:"variant",nodeKey:"owner",schemaKey:"Button",unstructuredViewCode:true)
      for edge in [bySource,byPropertyAlias,byElementAlias]:
        vm.inspector.selectedElement.val=element
        vm.designSystemSchema.val=DesignSystemSchema(nodes: @[node],sourceOwnership: @[edge])
        check scope.textContent=="Component schema"
      let byPath=DesignSourceOwnership(property:"variant",nodeKey:"owner",domPath:"/actual",unstructuredViewCode:true)
      vm.designSystemSchema.val=DesignSystemSchema(nodes: @[node],sourceOwnership: @[byPath])
      element.domPath="/actual";vm.inspector.selectedElement.val=element
      check scope.textContent=="Component schema"
      element.domPath="/different";vm.inspector.selectedElement.val=element
      check scope.textContent=="Unknown"
      element.domPath="";vm.inspector.selectedElement.val=element
      check scope.textContent=="Unknown"
      # Known independent aliases cannot waive a required-but-unknown path.
      for edge in [bySource,byPropertyAlias,byElementAlias]:
        var requiredPath=edge;requiredPath.domPath="/actual"
        vm.designSystemSchema.val=DesignSystemSchema(nodes: @[node],sourceOwnership: @[requiredPath])
        check scope.textContent=="Unknown"
        check resolveDesignSourceOwnership(vm.designSystemSchema.val,element,"variant").nodeKey=="owner"
      dispose()

  test "impact summary keeps mapped owners fresh without hypothetical scopes":
    createRoot do(dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)
      let impact = findByAttr(root, "data-design-system-impact", "true")
      var node = DesignSchemaNode(key: "classes.card.padding",
        kind: dsnClassDefinition, name: "card", property: "padding",
        value: "16px", sourceSpan: SourceSpan(file: "card.css", line: 1),
        components: @["Card"], usageCount: 7)
      vm.designSystemSchema.val = DesignSystemSchema(nodes: @[node])
      vm.inspector.selectedElement.val = ElementRef(id: "card", tag: "div",
        properties: @[PropertyInfo(name: "padding", value: "16px",
          sourceFile: "card.css", sourceLine: 1,
          schemaKey: node.key, sharedCount: 7, directStyleAllowed: true)])
      # General consumers still receive hypothetical scopes and their refusal
      # diagnostics; only the Source summary asks for declared owners.
      check vm.sharedDesignPropertyEditors().anyIt(
        it.sourceScope.schemaKey.len == 0 and it.diagnostics.len > 0)
      check impact.attributes["data-shared-design-editor-count"] == "1"
      check impact.textContent.contains("padding | Spacing | Shared class")
      check impact.textContent.contains("7 mapped uses")
      node.usageCount = 12
      vm.designSystemSchema.val = DesignSystemSchema(nodes: @[node])
      check impact.textContent.contains("12 mapped uses")
      vm.inspector.selectedElement.val = ElementRef(id: "other", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "#112233",
          sourceFile: "other.css", sourceLine: 1,
          schemaKey: "classes.other.color", directStyleAllowed: true)])
      check impact.attributes["data-shared-design-editor-count"] == "0"
      check not impact.textContent.contains("padding")
      node = DesignSchemaNode(key: "classes.other.color",
        kind: dsnClassDefinition, name: "other", property: "background-color",
        value: "#112233", sourceSpan: SourceSpan(file: "other.css", line: 1),
        components: @["Other"], usageCount: 3)
      vm.designSystemSchema.val = DesignSystemSchema(nodes: @[node])
      check impact.attributes["data-shared-design-editor-count"] == "1"
      check impact.textContent.contains("background-color | Color | Shared class")
      check impact.textContent.contains("3 mapped uses")
      # A declared owner with an unsupported family still needs its visible
      # diagnostic card; mapped-only is not an editable-only filter.
      node.key = "classes.other.clip"
      node.property = "clip-path"
      node.value = "inset(0)"
      vm.designSystemSchema.val = DesignSystemSchema(nodes: @[node])
      vm.inspector.selectedElement.val = ElementRef(id: "clip", tag: "div",
        properties: @[PropertyInfo(name: "clip-path", value: "inset(0)",
          sourceFile: "other.css", sourceLine: 1,
          schemaKey: node.key, directStyleAllowed: true)])
      check impact.attributes["data-shared-design-editor-count"] == "1"
      check impact.textContent.contains("clip-path | Unsupported | Shared class")
      let diagnostics = vm.sharedDesignPropertyEditors(mappedOnly = true)
      check diagnostics.len == 1
      check diagnostics[0].status == sdesUnsupported
      check diagnostics[0].diagnostics.len > 0
      dispose()
