## Actual selected private Replay consumes the genuine owner cursor. First read
## preserves null before facade erasure; second exercises ordinary public read.
## Public/NE clock prefixes are checked against actual decoded Record bits.
import std/json
import isonim/core/[clock,nondet]
import isonim/core/private/replay_reads
import nim_everywhere/time as neTime
var selected:ClockBase
proc stRpInit(context:cstring) {.exportc.} =
  selected=newInternalReadReplay(parseJson($context))
  currentClock=selected
proc stRpMono():float64 {.exportc.} = currentClock.now()
proc stRpNeMono():cstring {.exportc.} = ($neTime.monotonicNowMs()).cstring
proc stReplay(kind,phase:cint;defaultKey:bool;raw:cstring):cstring {.exportc.} =
  var key:string
  if kind!=3 and not defaultKey:key= $raw
  let observed=if phase==0:readReplayStorage(selected,kind.int,key)
               else: %(if kind==3:cookieGet() else:storageGet(key))
  var bytes=newJArray()
  for ch in observed.getStr():bytes.add(%ord(ch))
  ($(%*{"kind": $observed.kind,"bytes":bytes})).cstring
