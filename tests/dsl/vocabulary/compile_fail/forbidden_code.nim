# expect: E-A11Y-SECTIONING: 'section' is forbidden
# expect: Use 'mailSection' instead.
# expect-line: 12
## A forbidden entry with its own diagnostic code reports that code, not
## E-VOCAB-FORBIDDEN-TAG.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    section:
      text "x"
