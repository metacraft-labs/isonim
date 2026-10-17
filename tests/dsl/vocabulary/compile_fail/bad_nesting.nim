# expect: E-STRUCT-NESTING: 'p' must not be a child of 'mailSection'
# expect-line: 13
## A nesting violation below the top level of a block fails: `p` directly
## inside `mailSection` (the fixture allows it only in `mailColumn`). The
## top-level `mailSection` itself is fine, since its parent is unknown.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    mailSection:
      p: text "hi"
