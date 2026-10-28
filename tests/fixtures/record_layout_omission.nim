## A feature-off private import exposes no layout primitive or owner state.
import isonim/core/private/record_layout
static:
  doAssert not declared(RecordLayoutPrimitives)
  doAssert not declared(newInternalRecordLayout)
