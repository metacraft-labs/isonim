## Narrow metadata acceptance probe. The production editor performs DOM
## selection, native hydration, authentication, commit, compiler reload and
## history. This extra host mounts the genuine property choice widget ONLY
## when the actual selected-property list contains flex-direction; it never
## fabricates a PropertyInfo or writable capability. Baseline layout pills are
## outside this metadata prerequisite and are not used to claim parity here.
include editor_popup_workspace
import std/dom
import isonim/core/[computation, batch]
import isonim/editor/dom_renderer
import isonim/editor/views/widgets/[property_row, property_commit]
let probeHost = document.createElement("div")
probeHost.setAttribute("data-flex-metadata-probe", "true")
probeHost.setAttribute("style", "position:fixed;left:400px;top:60px;width:420px;z-index:10000;background:#20202a;padding:12px")
document.body.appendChild(probeHost)
createRenderEffect proc() =
  discard editor.selectedStory.val
  let el = editor.inspector.selectedElement.val
  let r = DomRenderer()
  r.clearChildren(probeHost)
  for property in el.properties:
    if property.name == "flex-direction":
      let selectedProperty = property
      untrack proc() =
        let value = createSignal(if selectedProperty.authoredValue.len > 0: selectedProperty.authoredValue else: selectedProperty.value)
        discard r.mountPropertyRow(probeHost, propertyRowChoice("Direction", value,
          @[(label:"Row",value:"row"),(label:"Column",value:"column"),
            (label:"Row reverse",value:"row-reverse"),(label:"Column reverse",value:"column-reverse")],
          wiring=editor.inspectorRowWiring("flex-direction")))
proc flexState(): cstring =
  var fields = newJArray()
  for property in editor.inspector.selectedElement.val.properties:
    fields.add %*{"name":property.name,"value":property.value,"authoredValue":property.authoredValue,
      "key":property.schemaKey,"nativeShared":property.nativeSourceShared,"count":property.sharedCount}
  cstring($(%*{"properties":fields,"reason":editor.inspectorRowWiring("flex-direction").readOnlyReason()}))
{.emit: ["window.__flexMetadata = {state:",flexState,"};"].}
