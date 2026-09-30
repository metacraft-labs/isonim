# expect: E-STRUCT-NESTING
# expect-line: 10
## mailColumn outside mailSection fails (nesting rule).
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    mailColumn(width = "50%"):
      p: text "hi"
