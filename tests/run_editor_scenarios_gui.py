#!/usr/bin/env python3
"""Official private Harbor browser acceptance; only absent sibling may skip.

The child Node runner drives the actual browser editor. This parent owns the
production launcher/Harbor/provider lifecycle and saves compiler/source evidence.
No transport, dispatcher, filesystem, compiler or rendered document is mocked.
"""
import subprocess
import time
import json
import os
from helpers.editor_scenario_runtime import Runtime, ROOT, HARBOR
from helpers.editor_process_observer import optional_sibling_available
if not optional_sibling_available(HARBOR):
    print('SKIP optional private Agent Harbor sibling absent')
else:
    runtime=Runtime('gui')
    try:
        child=runtime.spawn([os.environ.get('ISONIM_SCENARIO_NODE','node'),str(ROOT/'tests/test_editor_scenarios_gui.mjs'),str(runtime.artifacts/'context.json')],'browser')
        deadline=time.monotonic()+300
        identity=None
        observed={}
        while child.poll() is None:
            if time.monotonic()>=deadline:raise AssertionError('Actual browser workflow exceeded bounded lifetime')
            phase=runtime.artifacts/'phase'
            current=phase.read_text() if phase.exists() else ''
            if current in ('2','10','14') and current not in observed:
                actual=runtime.providerIdentity()
                if identity is None:identity=actual
                elif actual!=identity:raise AssertionError('Actual browser provider kernel identity changed')
                observed[current]=actual
            time.sleep(.03)
        if child.returncode:raise subprocess.CalledProcessError(child.returncode,child.args)
        if set(observed)!=set(('2','10','14')):raise AssertionError('Browser followup/reconnect/late turn provider observation required')
        if any(row[2] and row[2][0]==str(runtime.provider) and str(runtime.scenario) in row[2] for row in runtime.observer.snapshot().values()):
            raise AssertionError('Actual browser closed session left its provider alive')
        (runtime.artifacts/'browser-provider-continuity.json').write_text(json.dumps(observed,indent=2))
    finally:runtime.close()
