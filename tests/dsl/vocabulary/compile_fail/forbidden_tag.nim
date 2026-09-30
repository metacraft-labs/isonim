# expect: E-VOCAB-FORBIDDEN-TAG
# expect-line: 10
## Forbidden element fails naming the alternative.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    img(src = "x.png")
