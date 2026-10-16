## Calls the production wire serializer to measure actual Unicode quota units.
## Input is controlled protocol data; no serializer or transport is mocked.
import std/[json, syncio]
import isonim/editor/design_review/context_budget
let request = parseJson(stdin.readAll())
echo referenceContext(request["current"], request["base"], nil)
