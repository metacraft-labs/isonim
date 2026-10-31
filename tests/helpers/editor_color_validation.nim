## No mocks: expose the same native property validator used by the source worker
## to the browser CSS parser parity corpus. This helper does not claim filesystem
## persistence; genuine native source transaction tests cover that boundary.
import std/[json, os]
import isonim/editor/[types, viewmodels]
let values = parseJson(readFile(paramStr(1)))
var result = newJArray()
for value in values:
  let raw = value.getStr()
  let diagnostics = validateCssPropertyValue(PropertyInfo(name:"background-color", directStyleAllowed:true),
    PropertyEditRequest(property:"background-color",newValue:raw),parseCssPropertyValue("background-color",raw))
  result.add(%* {"value":raw,"accepted":diagnostics.len == 0})
echo result
