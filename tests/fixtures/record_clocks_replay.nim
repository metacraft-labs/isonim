## Real existing selected Replay implementation consumes primitive-produced log.
import ./replay_reads_bootstrap
import std/[times, json, monotimes]
import isonim/core/nondet
import nim_everywhere/time as neTime
proc mono(): cstring {.exportc: "rcReplayMono".} = ($nondet.now().ticks).cstring
proc neMono(): cstring {.exportc: "rcReplayNeMono".} = ($neTime.monotonicNowMs()).cstring
proc wall(): cstring {.exportc: "rcReplayWall".} =
  let value = nondet.wallNow()
  ($(%*{"seconds": $value.toUnix, "nanoseconds": value.nanosecond})).cstring
