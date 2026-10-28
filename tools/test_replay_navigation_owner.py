#!/usr/bin/env python3
"""Actual native/navigation owner gate; dependencies cannot be skipped.

Every inverse compiles its own source and fixture. Browser faults wrap/delegate
actual owner functions at bundle time; no fake cursor, privacy registry or URL.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile
root=Path(__file__).resolve().parent.parent
if not os.environ.get('CT_ARTIFACT'):
    raise SystemExit('CT_ARTIFACT required: navigation owner gate cannot skip')
env=dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE',shutil.which('chromium') or '')

def compile(name,flags=(),source=None,fixture=None):
    out=root/'build'/(name+'.js')
    cmd=['nim','js','-d:isonimInternalReplayReads',*flags]
    if source: cmd+=['--path:'+str(source),'--path:'+str(root.parent/'nim-everywhere/src')]
    cmd+=['--nimcache:'+str(root/'build/nimcache'/name),'--out:'+str(out),str(fixture or 'tests/fixtures/replay_navigation.nim')]
    subprocess.run(cmd,cwd=root,check=True)
    return out

def run(bundle,native,**extra):
    subprocess.run(['node','tests/test_replay_navigation_owner.mjs'],cwd=root,env={**env,'REPLAY_NAV_BUNDLE':str(bundle),'REPLAY_NAV_NATIVE':str(native),**extra},check=True)

# Ordinary/dormant artifacts must omit even escaped package paths/module frames.
for name,flags in [('ordinary',[]),('dormant',['-d:isonimRecordable'])]:
    out=root/'build'/('navigation-omission-'+name+'.js')
    subprocess.run(['nim','js','-d:nodejs',*flags,'--out:'+str(out),'tests/test_replay_read_guards.nim'],cwd=root,check=True)
    text=out.read_text()
    for marker in ['runtime-browser/dist/sensitive.js','loadNavigationOwner','navigationStates','internal navigation Replay','readReplayNavigationState']:
        assert marker not in text,(name,marker)
    subprocess.run(['node',str(out)],cwd=root,check=True)
    print(name+' navigation package/helpers/state/module omission PASS')

native=compile('replay-navigation-native')
for name,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('early',['-d:replayNavEarly'])]:
    product=compile('replay-navigation-'+name,flags)
    run(product,native,REPLAY_NAV_RECEIPT=str(root/'build'/('replay-navigation-'+name+'.json')))

for mutation in ['history','kind','relative','state','location','holing']:
    with tempfile.TemporaryDirectory(prefix='isonim-navigation-'+mutation+'-') as directory:
        tmp=Path(directory);shutil.copytree(root/'src',tmp/'src')
        fixtures=tmp/'tests/fixtures';fixtures.mkdir(parents=True)
        for name in ['replay_navigation.nim','replay_reads_bootstrap.nim']:
            shutil.copyfile(root/'tests/fixtures'/name,fixtures/name)
        path=tmp/'src/isonim/core/private/replay_reads.nim';code=path.read_text()
        if mutation=='history':
            path=tmp/'src/isonim/core/nondet.nim';code=path.read_text()
            old='''      if currentClock.isReadReplay:
        let selected = currentClock
        let owner = prepareReadReplayNavigation(selected)'''
            new='''      if false and currentClock.isReadReplay:
        let selected = currentClock
        let owner = prepareReadReplayNavigation(selected)'''
            assert code.count(old)==2;code=code.replace(old,new)
        elif mutation=='kind':
            path=tmp/'src/isonim/core/nondet.nim';code=path.read_text()
            old='completeReadReplayNavigation(selected, owner, 1, observed.browserUrl)';new='completeReadReplayNavigation(selected, owner, 2, observed.browserUrl)'
            assert code.count(old)==1;code=code.replace(old,new)
        elif mutation=='relative':
            # Restore authored URL checking, with parsing AFTER owner next so
            # the real cursor diagnoses the wrong checked argument itself.
            old="var parsed;try{parsed=new URL(u);}catch(e){s.valid=false;throw new Error('internal navigation Replay reflected URL unavailable');}"
            assert code.count(old)==1;code=code.replace(old,'var parsed;')
            old='s.current=u;s.pathname=parsed.pathname;';new='parsed=new URL(u);s.current=u;s.pathname=parsed.pathname;'
            assert code.count(old)==1;code=code.replace(old,new);path.write_text(code)
            path=tmp/'src/isonim/core/nondet.nim';code=path.read_text()
            old='completeReadReplayNavigation(selected, owner, 1, observed.browserUrl)';new='completeReadReplayNavigation(selected, owner, 1, some(url))'
            assert code.count(old)==1;code=code.replace(old,new)
        elif mutation=='state':
            old='    frameTasks: Table[int, JsObject]';assert code.count(old)==1;code=code.replace(old,old+'\n    navigationStates: JsObject')
            old='if navigationStates.isNil: navigationStates = newTimerNamespaces()';new='if selected.navigationStates.isNil: selected.navigationStates = newTimerNamespaces()'
            assert code.count(old)==1;code=code.replace(old,new)
            old='navigationState(navigationStates, selected.cursor,';new='navigationState(selected.navigationStates, selected.cursor,'
            assert code.count(old)==1;code=code.replace(old,new)
        elif mutation=='location':
            path=tmp/'src/isonim/core/nondet.nim';code=path.read_text();old='of "location": return %readReplayLocation(b)';new='of "location": discard # restore native location'
            assert code.count(old)==1;code=code.replace(old,new)
        else:
            old='url:o.holeText(u,o.currentSensitiveValues(window,sensitive))';new='url:u'
            assert code.count(old)==1;code=code.replace(old,new)
        path.write_text(code)
        output=compile('replay-navigation-inverse-'+mutation,source=tmp/'src',fixture=fixtures/'replay_navigation.nim')
        run(output,native,REPLAY_NAV_INVERSE=mutation,REPLAY_NAV_RECEIPT=str(root/'build'/('replay-navigation-inverse-'+mutation+'.json')))
