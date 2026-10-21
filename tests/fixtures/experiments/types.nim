import isonim/experiments
export experiments

type
  Cta* {.experimentKey: "home-cta".} = enum
    control, estimate, startFree
  Color* = enum
    plain, vivid
proc weights*(_: typedesc[Cta]): seq[int] = @[50, 25, 25]
proc window*(_: typedesc[Cta]): tuple[start, finish: string] =
  ("2026-10-01", "2027-01-01")
