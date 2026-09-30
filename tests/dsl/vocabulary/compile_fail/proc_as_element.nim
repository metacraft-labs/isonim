# expect: E-VOCAB-PROC-AS-ELEMENT
# expect-line: 12
## A data-only proc called with named arguments fails naming both fixes
## (proc-as-element probe). E-VOCAB-UNKNOWN-TAG also fires for the same line;
## both errors are true, and this is the actionable one.
import isonim/testing/mock_dom
import isonim/dsl/ui
import ../fixture_renderer

proc badTemplate(r: VocabRenderer): MockNode =
  ui(r):
    footerBlock(label = "x")
