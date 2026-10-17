# expect: E-STRUCT-NESTING: 'mailDocument' must be the top-level element of its ui block
# expect-line: 12
## A document-root-only tag nested inside another element fails, even
## though top-level elements are not nesting-checked.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    mailSection:
      mailDocument:
        mailSection:
          mailColumn:
            p: text "hi"
