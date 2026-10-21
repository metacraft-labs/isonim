import isonim/experiments
when defined(badEnumStart):
  type Bad = enum
    first = 1, second
elif defined(badEnumHole):
  type Bad = enum
    first = 0, second = 2
else:
  type Bad = enum
    first, second
proc weights(_: typedesc[Bad]): seq[int] =
  when defined(badWeightCount): @[1]
  elif defined(badWeightNegative): @[1, -1]
  elif defined(badWeightTotal): @[0, 0]
  else: @[1, 1]
proc window(_: typedesc[Bad]): tuple[start, finish: string] =
  when defined(badDate): ("2026-02-29", "2026-03-01")
  elif defined(badDateOrder): ("2026-10-22", "2026-01-01")
  else: ("2026-01-01", "2027-01-01")
discard useExperiment[Bad]()
