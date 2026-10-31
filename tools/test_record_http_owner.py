#!/usr/bin/env python3
"""Qualify fixed Record HTTP with the shared production-boundary driver."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).with_name('http_owner_qualification.py')), run_name='__main__', init_globals={'REPLAY_HTTP':False})
