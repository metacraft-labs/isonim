# Negative ordering control: this factory's nondet import initializes too early.
import isonim/core/nondet
import ./nondet_bridge_cursor_clock
proc makeLateClock*(): ClockBase = newCursorClock(contextSeed())
