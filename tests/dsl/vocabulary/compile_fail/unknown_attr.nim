# expect: E-VOCAB-UNKNOWN-ATTR
# expect-line: 10
## Unknown attribute on a known tag fails.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    mailSection(bogus_attr = "x")
