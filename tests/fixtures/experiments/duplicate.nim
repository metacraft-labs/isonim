import isonim/experiments
type
  A {.experimentKey: "same".} = enum
    a0, a1
  B {.experimentKey: "same".} = enum
    b0, b1, b2
discard useExperiment[A]()
discard useExperiment[B]()
