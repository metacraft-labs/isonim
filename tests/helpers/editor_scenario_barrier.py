#!/usr/bin/env python3
"""Observable scheduling barrier only; no substituted tools or tool results."""
from pathlib import Path
import sys
import time
path = Path(sys.argv[1])
deadline = time.monotonic() + 60
while not path.exists():
    if time.monotonic() >= deadline:
        raise TimeoutError('Scenario release barrier was never observed')
    time.sleep(.02)
