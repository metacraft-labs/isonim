# expect: E-STRUCT-NESTING: 'table' must not be a child of 'mailSection'
# expect: Use 'mailTable' instead.
# expect-line: 14
## A nesting violation on a tag that declares an alternative names it.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    mailSection:
      mailColumn:
        table: text "ok here"
      table: text "not here"
