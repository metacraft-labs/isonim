# expect: E-VOCAB-UNKNOWN-TAG
# expect-line: 10
## Typo'd tag fails naming the nearest entry.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    mailSectoin(width = "50%")
