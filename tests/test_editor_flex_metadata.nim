## Real previewDomElementRef normalization, using the browser's existing JSON
## event shape and computedStyles wire. No renderer, source adapter or compiler
## is mocked. GUI acceptance separately obtains this wire from getComputedStyle
## in the production preview and hydrates it with real native ownership.
import std/[unittest, json, sequtils]
import isonim/editor/[viewmodels, types, style_provenance_decode]

proc selection(wire: string): ElementRef =
  let event = %*{"computedStyles": wire, "display": "inline-flex", "elementId": "action"}
  previewDomElementRef(StoryRenderMetadata(sourceFile: "stories.nim", sourceLine: 1),
    tag="button", testId="", className="", role="", elementPath="", ancestry="",
    sourceFile="stories.nim", sourceLine=1, display=event["display"].getStr,
    position="static", backgroundColor="rgb(17, 34, 51)", color="rgb(255, 255, 255)",
    padding="4px", margin="0px", width="120px", height="36px", borderRadius="4px",
    borderWidth="0px", borderStyle="none", borderColor="rgb(0, 0, 0)", fontSize="16px",
    fontWeight="400", lineHeight="normal", boxShadow="none", opacity="1",
    rectWidth="120", rectHeight="36", textContent="Action", elementId=event["elementId"].getStr,
    sourceKey="", schemaKey="", ancestorIds="", layerTreeJson="",
    computedStyles=event["computedStyles"].getStr)

suite "Preview flex direction metadata":
  test "production capture includes direction without losing existing fields":
    check "flex-direction" in inspectorEditableCssProperties
    for name in ["display", "width", "padding", "background-color", "opacity"]:
      check name in inspectorEditableCssProperties
  test "all four computed directions survive selection normalization":
    for direction in ["row", "column", "row-reverse", "column-reverse"]:
      let el = selection("display=inline-flex;flex-direction=" & direction & ";width=120px")
      let props = el.properties.filterIt(it.name == "flex-direction")
      check props.len == 1
      check props[0].value == direction
      check props[0].origin == poInherited
      check props[0].authoredValue == ""
      check not props[0].nativeSourceShared
      check el.properties.filterIt(it.name == "display")[0].value == "inline-flex"
      check el.properties.filterIt(it.name == "width")[0].value == "120px"
      check el.id == "action"
  test "legacy messages do not manufacture authoring ownership or direction":
    let el = selection("")
    check el.properties.filterIt(it.name == "flex-direction").len == 0
    check el.properties.filterIt(it.name == "width")[0].value == "120px"
  test "duplicates and malformed records retain one legitimate computed field":
    let el = selection("garbage;=column;flex-direction=;flex-direction=column-reverse;flex-direction=row")
    let props = el.properties.filterIt(it.name == "flex-direction")
    check props.len == 1
    check props[0].value == "column-reverse"
