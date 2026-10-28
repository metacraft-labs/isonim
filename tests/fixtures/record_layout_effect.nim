## Include the actual leaf solely to expose its private raw boundary to ceilings.
## No implementation substitute or test-only production hook is introduced.
include ../../src/isonim/core/private/record_layout
when defined(recordLayoutReject):
  proc observe(p: RecordLayoutPrimitives): RecordViewportObservation {.tags: [].} =
    when defined(recordLayoutRaw): viewportRaw(p.linkage)
    else: recordViewport(p)
else:
  proc observe(p: RecordLayoutPrimitives): RecordViewportObservation {.tags: [RawNondet].} =
    when defined(recordLayoutRaw): viewportRaw(p.linkage)
    else: recordViewport(p)
proc keep(p: RecordLayoutPrimitives): RecordViewportObservation {.exportc: "rlEffect".} = observe(p)
