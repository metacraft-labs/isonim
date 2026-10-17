#!/usr/bin/env python3
"""Real private stdio/process lifetime controls; no model/native/provider ACKs.

A tiny Python byte-echo fixture deliberately substitutes ONLY application logic
so real pipes, EOF, blocked inherited stdout, signals, descendants, zombies and
subreaper ownership can be tested deterministically without inference. Its JSON
payload is transport data, never Claude/ACP ACK or delivery proof. Actual pinned
SDK/native zero-user controls and official Harbor workflows remain mandatory.
Copied/mutated durable receipts below are explicitly synthetic schema negatives.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import threading
import array
import fcntl
import termios
from helpers.editor_provider_closure import identity,probe,attest_completion,authenticate_progress,wait_completion
ROOT=Path(__file__).resolve().parent.parent
ctypes.CDLL(None).prctl(36,1,0,0,0) # this test process only adopts its descendants

class Closure(unittest.TestCase):
    def test_real_graceful_and_force_killed_producers_with_durable_receipts(self):
        self.results=[]
        for mode in ('graceful','blocked-EOF','force-kill'):
            with self.subTest(mode=mode):
                root=Path(tempfile.mkdtemp(prefix='isonim-wire-lifetime-'));root.chmod(0o700);private=root/'private';private.mkdir(mode=0o700)
                native_script=root/'owned-native.py';native_script.write_text("import sys\nfor line in sys.stdin:pass\n"+("from pathlib import Path\nimport time\np=Path("+repr(str(root))+")\n(p/'eof-ready').write_text('ready')\nwhile not (p/'release-eof').exists():time.sleep(.01)\n" if mode=='blocked-EOF' else ''))
                fixture=root/'fixture.py';fixture.write_text("import subprocess,sys,json\nfrom pathlib import Path\np=subprocess.Popen([sys.executable,sys.argv[2]],stdin=subprocess.PIPE)\nPath(sys.argv[1]+'/native.pid').write_text(str(p.pid))\nfor line in sys.stdin.buffer:\n sys.stdout.buffer.write(line);sys.stdout.buffer.flush()\np.stdin.close();p.wait()\n")
                log=(private/'stderr.log').open('wb');os.fchmod(log.fileno(),0o600)
                command="from pathlib import Path;import sys;sys.path.insert(0,sys.argv[1]);from editor_provider_wire import observe_provider;sys.exit(observe_provider(Path(sys.argv[2]),Path(sys.executable),[sys.executable,sys.argv[3],sys.argv[2],sys.argv[4]]))"
                child=subprocess.Popen([sys.executable,'-c',command,str(ROOT/'tests/helpers'),str(root),str(fixture),str(native_script)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,start_new_session=True)
                try:
                    payload=b'{"fixture":"actual byte echo Unicode \\u2603"}\n';child.stdin.write(payload);child.stdin.flush();self.assertEqual(child.stdout.readline(),payload)
                    deadline=time.monotonic()+5
                    while not (private/'provider-wire-progress.json').exists() or not (root/'native.pid').exists() or json.loads((private/'provider-wire-progress.json').read_text()).get('frames')!=2:
                        self.assertLess(time.monotonic(),deadline);time.sleep(.01)
                    launch=json.loads((root/'real-provider-launch.json').read_text());writers={'observer':identity(child.pid),'acp':identity(launch['provider_pid'])};native=identity(int((root/'native.pid').read_text()))
                    progress=authenticate_progress(private,writers['observer']);self.assertEqual(progress['frames'],2)
                    live={'processes':{label:{'pid':point['pid'],'originalStarttime':point['starttime'],'state':'absent'} for label,point in {**writers,'native':native}.items()}}
                    with self.assertRaisesRegex(AssertionError,'still exists'):attest_completion(private,writers,native,live)
                    before=time.monotonic()
                    if mode!='force-kill':
                        child.stdin.close()
                        if mode=='blocked-EOF':
                            deadline=time.monotonic()+5
                            while not (root/'eof-ready').exists():
                                self.assertLess(time.monotonic(),deadline);time.sleep(.01)
                            self.assertEqual(probe(native)['state'],'live')
                            self.assertEqual(probe(writers['observer'])['state'],'live')
                            with self.assertRaises(AssertionError):attest_completion(private,writers,native,live)
                            (private/'blocked-lifetime.json').write_text(json.dumps({label:probe(point) for label,point in {**writers,'native':native}.items()}))
                            (root/'release-eof').write_text('release')
                    else:os.killpg(child.pid,signal.SIGKILL)
                    child.wait(timeout=5)
                    # Real adopted descendants must be reaped, not zombies
                    # incorrectly treated as disappearance by a PID snapshot.
                    deadline=time.monotonic()+5
                    while True:
                        try:
                            pid,_=os.waitpid(-1,os.WNOHANG)
                            if pid:continue
                        except ChildProcessError:break
                        self.assertLess(time.monotonic(),deadline);time.sleep(.01)
                    state=wait_completion(private,writers,native,private/'lifetime-snapshots.json')
                    self.assertLess(time.monotonic()-before,15)
                    self.assertEqual(state['origin'],'host-quiescence' if mode=='force-kill' else 'child-finally')
                    self.assertTrue(state['complete']);self.assertEqual(state['errors'],[])
                    if mode=='force-kill':
                        self.assertIsNone(state['providerExit']);self.assertIsNone(state['requestReaderAliveAtProviderExit']);self.assertFalse(state['childFinallyObserved'])
                    self.results.append({'mode':mode,'artifacts':str(root),'origin':state['origin'],'seconds':time.monotonic()-before,'allOriginalPidsAbsent':all(probe(point)['state']=='absent' for point in {**writers,'native':native}.values())})
                    if mode=='force-kill':self.negative_receipts(private,writers,native)
                finally:
                    if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait()
                    if not child.stdin.closed:child.stdin.close()
                    child.stdout.close();log.close()
        print(json.dumps({'actualOwnedProcessControls':self.results}),flush=True)

    def test_real_simultaneous_large_bidirectional_bytes(self):
        root=Path(tempfile.mkdtemp(prefix='isonim-wire-backpressure-'));root.chmod(0o700);private=root/'private';private.mkdir(mode=0o700)
        fixture=root/'large-duplex.py';fixture.write_text("import sys,json,hashlib\nfirstByte=sys.stdin.buffer.read(1)\nfirst=(json.dumps({'fixtureOutput':'OUT'*1048576})+'\\n').encode()\nsys.stdout.buffer.write(first);sys.stdout.buffer.flush()\nsys.stdout.buffer.write(first);sys.stdout.buffer.flush()\nincoming=firstByte+sys.stdin.buffer.readline()\nsys.stdout.buffer.write((json.dumps({'fixtureInputSha256':hashlib.sha256(incoming).hexdigest()})+'\\n').encode());sys.stdout.buffer.flush()\n")
        command="from pathlib import Path;import sys;sys.path.insert(0,sys.argv[1]);from editor_provider_wire import observe_provider;sys.exit(observe_provider(Path(sys.argv[2]),Path(sys.executable),[sys.executable,sys.argv[3]]))"
        helpers=os.environ.get('ISONIM_WIRE_CONTROL_HELPERS',str(ROOT/'tests/helpers'))
        log=(private/'stderr.log').open('wb');os.fchmod(log.fileno(),0o600)
        child=subprocess.Popen([sys.executable,'-c',command,helpers,str(root),str(fixture)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,start_new_session=True)
        incoming=(json.dumps({'fixtureInput':'INPUT'*1048576})+'\n').encode();received=[];errors=[]
        def send():
            try:child.stdin.write(incoming);child.stdin.flush()
            except BaseException as error:errors.append(type(error).__name__)
        def receive():
            try:
                for _ in range(3):received.append(child.stdout.readline())
            except BaseException as error:errors.append(type(error).__name__)
        writer=threading.Thread(target=send);reader=threading.Thread(target=receive);started=time.monotonic();writer.start();reader.start()
        try:
            writer.join(5);reader.join(5)
            self.assertFalse(writer.is_alive(),'actual large stdin must drain independently of stdout')
            self.assertFalse(reader.is_alive(),'actual large stdout must drain independently of stdin')
            self.assertEqual(errors,[])
            self.assertEqual(received[0],(json.dumps({'fixtureOutput':'OUT'*1048576})+'\n').encode())
            self.assertEqual(received[1],received[0])
            self.assertEqual(received[2],(json.dumps({'fixtureInputSha256':hashlib.sha256(incoming).hexdigest()})+'\n').encode())
            child.stdin.close();child.wait(timeout=5)
            print(json.dumps({'actualLargeDuplex':True,'inputBytes':len(incoming),'outputBytes':sum(map(len,received)),'exactBytesEqual':True,'seconds':time.monotonic()-started,'artifacts':str(root)}),flush=True)
        finally:
            launch_file=root/'real-provider-launch.json';pids={'observer':child.pid}
            if launch_file.exists():pids['fixture']=json.loads(launch_file.read_text())['provider_pid']
            observations={}
            for label,pid in pids.items():
                try:point=identity(pid);observations[label]={'identity':point,'probe':probe(point)}
                except (FileNotFoundError,ProcessLookupError):observations[label]={'pid':pid,'state':'absent'}
            fd=os.open(private/'backpressure-before-cleanup.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,'w') as output:json.dump({'monotonic':time.monotonic(),'processes':observations,'writerAlive':writer.is_alive(),'readerAlive':reader.is_alive(),'receivedLineBytes':[len(line) for line in received]},output)
            if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait()
            writer.join(5);reader.join(5)
            if not child.stdin.closed:child.stdin.close()
            child.stdout.close();log.close()


    def test_actual_consumed_partial_input_output_and_utf8_reject_completion(self):
        results=[]
        for direction,tail,ending in [('request',b'{"incompleteIngress":','kill'),('response',b'{"incompleteIngress":','kill'),
                ('request',b'{"unicode":"\xf0\x9f','kill'),('response',b'{"unicode":"\xf0\x9f','kill'),
                ('request',b'{"eof":','eof'),('response',b'{"eof":','eof')]:
            with self.subTest(direction=direction,ending=ending,tailSha256=hashlib.sha256(tail).hexdigest()):
                root=Path(tempfile.mkdtemp(prefix='isonim-wire-partial-'));root.chmod(0o700);private=root/'private';private.mkdir(mode=0o700)
                # Only application byte-echo logic is substituted. FIONREAD on
                # the actual original pipe independently proves consumption;
                # real recorder and completion validator are never mocked.
                fixture=root/'fixture.py'
                fixture.write_text("import sys,os,time,threading,array,fcntl,termios,json\nfrom pathlib import Path\nroot=Path(sys.argv[1])\ndef emit():\n while not (root/'emit').exists():time.sleep(.005)\n tail=bytes.fromhex((root/'emit').read_text())\n for chunk in [tail[:-1],tail[-1:]]:\n  os.write(sys.stdout.fileno(),chunk)\n  deadline=time.monotonic()+5\n  while True:\n   n=array.array('i',[0]);fcntl.ioctl(sys.stdout.fileno(),termios.FIONREAD,n,True)\n   if n[0]==0:break\n   assert time.monotonic()<deadline;time.sleep(.005)\n  time.sleep(.02)\n (root/'output-consumed.json').write_text(json.dumps({'pipeAvailableBytes':n[0],'bytes':len(tail),'pid':os.getpid(),'pipeIdentity':os.readlink('/proc/self/fd/1')}))\n while not (root/'exit').exists():time.sleep(.005)\n os._exit(0)\nthreading.Thread(target=emit,daemon=True).start()\nfor line in sys.stdin.buffer:\n os.write(sys.stdout.fileno(),line)\n")
                command="from pathlib import Path;import sys;sys.path.insert(0,sys.argv[1]);from editor_provider_wire import observe_provider;sys.exit(observe_provider(Path(sys.argv[2]),Path(sys.executable),[sys.executable,sys.argv[3],sys.argv[2]]))"
                log=(private/'stderr.log').open('wb');os.fchmod(log.fileno(),0o600)
                child=subprocess.Popen([sys.executable,'-c',command,str(ROOT/'tests/helpers'),str(root),str(fixture)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,start_new_session=True)
                try:
                    payload=b'{"complete":"actual"}\n';child.stdin.write(payload);child.stdin.flush();self.assertEqual(child.stdout.readline(),payload)
                    deadline=time.monotonic()+5
                    while not (private/'provider-wire-progress.json').exists() or json.loads((private/'provider-wire-progress.json').read_text())['frames']!=2:
                        self.assertLess(time.monotonic(),deadline);time.sleep(.005)
                    launch=json.loads((root/'real-provider-launch.json').read_text());writers={'observer':identity(child.pid),'acp':identity(launch['provider_pid'])};native=writers['acp'];before=authenticate_progress(private,writers['observer'])
                    if direction=='request':
                        for chunk in [tail[:-1],tail[-1:]]:
                            child.stdin.write(chunk);child.stdin.flush()
                            while True:
                                n=array.array('i',[0]);fcntl.ioctl(child.stdin.fileno(),termios.FIONREAD,n,True)
                                if n[0]==0:break
                                self.assertLess(time.monotonic(),deadline);time.sleep(.005)
                            time.sleep(.02)
                        consumed={'pipeAvailableBytes':n[0],'bytes':len(tail),'pid':child.pid,'pipeIdentity':os.readlink('/proc/self/fd/'+str(child.stdin.fileno()))}
                    else:
                        (root/'emit').write_text(tail.hex())
                        while not (root/'output-consumed.json').exists():
                            self.assertLess(time.monotonic(),deadline);time.sleep(.005)
                        consumed=json.loads((root/'output-consumed.json').read_text())
                    self.assertEqual(consumed['pipeAvailableBytes'],0);self.assertEqual(probe(writers['observer'])['state'],'live')
                    while True:
                        progress=json.loads((private/'provider-wire-progress.json').read_text())
                        if progress['ingress']['directions'][direction]['unforwardedBytes']==len(tail):break
                        self.assertLess(time.monotonic(),deadline);time.sleep(.005)
                    self.assertEqual(progress['frames'],before['frames'])
                    # After durable publication, prove the real owning reader
                    # has reached its next blocking read on that exact pipe.
                    # This excludes a sleep-only assumption about local pending.
                    blocked=[]
                    while not blocked:
                        for task in (Path('/proc')/str(child.pid)/'task').iterdir():
                            call=(task/'syscall').read_text().split()
                            if len(call)>1 and call[0]=='0':
                                fd=int(call[1],0)
                                try:pipe=os.readlink('/proc/'+str(child.pid)+'/fd/'+str(fd))
                                except FileNotFoundError:continue
                                if pipe==consumed['pipeIdentity']:blocked.append({'tid':int(task.name),'syscall':'read','fd':fd,'pipeIdentity':pipe})
                        if not blocked:self.assertLess(time.monotonic(),deadline);time.sleep(.005)
                    with (private/'observed-before-teardown.json').open('w') as output:
                        os.fchmod(output.fileno(),0o600);json.dump({'consumption':consumed,'writers':writers,'native':native,'observerProbe':probe(writers['observer']),'nextBlockingRead':blocked,'progress':progress},output)
                    if ending=='kill':os.killpg(child.pid,signal.SIGKILL)
                    elif direction=='request':child.stdin.close()
                    else:(root/'exit').write_text('exit')
                    child.wait(timeout=5)
                    while True:
                        try:
                            pid,_=os.waitpid(-1,os.WNOHANG)
                            if pid:continue
                        except ChildProcessError:break
                        self.assertLess(time.monotonic(),deadline);time.sleep(.005)
                    self.assertTrue(all(probe(point)['state']=='absent' for point in writers.values()))
                    with self.assertRaises(AssertionError):wait_completion(private,writers,native,private/'completion-snapshots.json')
                    # Completion must fail without inventing a host receipt. An
                    # actual child-finally EOF receipt can exist, but not pass.
                    state=private/'provider-wire-state.json'
                    if state.exists():self.assertEqual(json.loads(state.read_text())['origin'],'child-finally')
                    results.append({'direction':direction,'ending':ending,'observedTailBytes':len(tail),'actualPipeEmpty':True,'rejected':True,'artifacts':str(root)})
                finally:
                    if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait()
                    if not child.stdin.closed:child.stdin.close()
                    child.stdout.close();log.close()
        print(json.dumps({'actualConsumedFragmentControls':results}),flush=True)

    def test_complete_chunked_unicode_bytes_pass_exactly(self):
        root=Path(tempfile.mkdtemp(prefix='isonim-wire-chunked-'));root.chmod(0o700);private=root/'private';private.mkdir(mode=0o700)
        fixture=root/'echo.py';fixture.write_text("import sys,os,time\nfor line in sys.stdin.buffer:\n for byte in line:\n  os.write(sys.stdout.fileno(),bytes([byte]));time.sleep(.001)\n")
        command="from pathlib import Path;import sys;sys.path.insert(0,sys.argv[1]);from editor_provider_wire import observe_provider;sys.exit(observe_provider(Path(sys.argv[2]),Path(sys.executable),[sys.executable,sys.argv[3]]))"
        log=(private/'stderr.log').open('wb');os.fchmod(log.fileno(),0o600)
        child=subprocess.Popen([sys.executable,'-c',command,str(ROOT/'tests/helpers'),str(root),str(fixture)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,start_new_session=True)
        try:
            payload='{"unicode":"☃🚀"}\n'.encode()
            for byte in payload:
                child.stdin.write(bytes([byte]));child.stdin.flush();time.sleep(.002)
            self.assertEqual(child.stdout.readline(),payload)
            launch=json.loads((root/'real-provider-launch.json').read_text());writers={'observer':identity(child.pid),'acp':identity(launch['provider_pid'])};native=writers['acp']
            deadline=time.monotonic()+5
            while json.loads((private/'provider-wire-progress.json').read_text())['frames']!=2:
                self.assertLess(time.monotonic(),deadline);time.sleep(.005)
            progress=authenticate_progress(private,writers['observer']);self.assertGreater(progress['ingress']['chunks'],2)
            child.stdin.close();child.wait(timeout=5)
            state=wait_completion(private,writers,native,private/'completion-snapshots.json');self.assertEqual(state['origin'],'child-finally')
            print(json.dumps({'actualChunkedUnicodeBytesEqual':True,'chunks':progress['ingress']['chunks'],'artifacts':str(root)}),flush=True)
        finally:
            if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait()
            if not child.stdin.closed:child.stdin.close()
            child.stdout.close();log.close()

    def negative_receipts(self,private,writers,native):
        base=private.parent/'negatives';base.mkdir(mode=0o700);original=json.loads((private/'provider-wire-progress.json').read_text())
        mutations=[('missing',lambda p:p.unlink()),('false-origin',lambda p:p.write_text(json.dumps({**original,'origin':False}))),('error',lambda p:p.write_text(json.dumps({**original,'errors':[{'where':'synthetic'}]}))),('stale',lambda p:p.write_text(json.dumps({**original,'traceSha256':'0'*64}))),('wrong-writer',lambda p:p.write_text(json.dumps({**original,'writer':{**original['writer'],'starttime':'0'}}))),('false-count',lambda p:p.write_text(json.dumps({**original,'frames':True}))),('wrong-chain',lambda p:p.write_text(json.dumps({**original,'chain':'0'*64})))]
        for name,mutate in mutations:
            area=base/name;shutil.copytree(private,area);mutate(area/'provider-wire-progress.json')
            with self.subTest(negative=name),self.assertRaises((AssertionError,FileNotFoundError)):authenticate_progress(area,writers['observer'])
        for name,file in [('truncated-trace','real-provider-wire.jsonl'),('truncated-receipt','provider-wire-receipts.jsonl')]:
            area=base/name;shutil.copytree(private,area);p=area/file;p.write_bytes(p.read_bytes()[:-1])
            with self.subTest(negative=name),self.assertRaises(AssertionError):authenticate_progress(area,writers['observer'])
        for name,mutate in [('wrong-order',lambda item:item.update(order=99)),('wrong-original-frame-hash',lambda item:item.update(wireFrameSha256='0'*64)),('wrong-direction',lambda item:item.update(direction='request')),('false-line',lambda item:item.update(completeLine=False))]:
            area=base/name;shutil.copytree(private,area);file=area/'provider-wire-receipts.jsonl';rows=[json.loads(line) for line in file.read_text().splitlines()];mutate(rows[-1]);chain='0'*64
            for item in rows:
                item['previousChain']=chain;body={key:value for key,value in item.items() if key!='chain'};chain=hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest();item['chain']=chain
            file.write_text(''.join(json.dumps(item)+'\n' for item in rows));progress={**original,'chain':chain,'receiptsSha256':hashlib.sha256(file.read_bytes()).hexdigest()};(area/'provider-wire-progress.json').write_text(json.dumps(progress))
            with self.subTest(consistent_rehashed_negative=name),self.assertRaises(AssertionError):authenticate_progress(area,writers['observer'])
        for name,mutate in [('missing-ingress',lambda area:(area/'provider-wire-ingress.jsonl').unlink()),
                ('false-ingress',lambda area:(area/'provider-wire-progress.json').write_text(json.dumps({**original,'ingress':False}))),
                ('truncated-ingress',lambda area:(area/'provider-wire-ingress.jsonl').write_bytes((area/'provider-wire-ingress.jsonl').read_bytes()[:-1]))]:
            area=base/name;shutil.copytree(private,area);mutate(area)
            with self.subTest(ingress=name),self.assertRaises((AssertionError,FileNotFoundError)):authenticate_progress(area,writers['observer'])
        for name,mutate in [('gap',lambda rows:rows[-1].update(order=99)),('duplicate',lambda rows:rows.append(dict(rows[-1]))),
                ('wrong-direction',lambda rows:rows[-1].update(direction='request')),('wrong-byte-hash',lambda rows:rows[-1].update(sha256='0'*64)),
                ('false-byte-count',lambda rows:rows[-1].update(bytes=True)),('changed-bytes',lambda rows:rows[-1].update(privateBytesBase64='e30K',bytes=3,sha256=hashlib.sha256(b'{}\n').hexdigest()))]:
            area=base/('rehash-ingress-'+name);shutil.copytree(private,area);file=area/'provider-wire-ingress.jsonl';rows=[json.loads(line) for line in file.read_text().splitlines()];mutate(rows);chain='0'*64
            for item in rows:
                item['previousChain']=chain;chain=hashlib.sha256(json.dumps({key:value for key,value in item.items() if key!='chain'},sort_keys=True).encode()).hexdigest();item['chain']=chain
            file.write_text(''.join(json.dumps(item)+'\n' for item in rows));progress=json.loads(json.dumps(original));progress['ingress'].update(chain=chain,chunks=len(rows),journalSha256=hashlib.sha256(file.read_bytes()).hexdigest());(area/'provider-wire-progress.json').write_text(json.dumps(progress))
            with self.subTest(consistent_rehashed_ingress=name),self.assertRaises(AssertionError):authenticate_progress(area,writers['observer'])
        for name,value in [('unforwarded-zero',False),('wrong-observed',0),('stale-observed-hash','0'*64)]:
            area=base/name;shutil.copytree(private,area);progress=json.loads(json.dumps(original));point=progress['ingress']['directions']['request'];point[{'unforwarded-zero':'unforwardedBytes','wrong-observed':'observedBytes','stale-observed-hash':'observedSha256'}[name]]=value;(area/'provider-wire-progress.json').write_text(json.dumps(progress))
            with self.subTest(ingress_progress=name),self.assertRaises(AssertionError):authenticate_progress(area,writers['observer'])
        snapshot=json.loads((private/'lifetime-snapshots.json').read_text())['snapshots'][-1]
        for value in (False,None,'missing','error','errors','exit','reader','namespace'):
            area=base/('child-state-'+str(value));shutil.copytree(private,area);state=json.loads((area/'provider-wire-state.json').read_text());state['origin']='child-finally'
            if value=='missing':state.pop('complete')
            elif value=='errors':state['complete']=True;state['errors']=[{'where':'synthetic-error'}]
            elif value=='exit':state['complete']=True;state['providerExit']=False
            elif value=='reader':state['complete']=True;state['requestReaderAliveAtProviderExit']=None
            elif value=='namespace':state['complete']=True;state['observerPid']=0
            else:state['complete']=value
            (area/'provider-wire-state.json').write_text(json.dumps(state))
            with self.subTest(child=value),self.assertRaises(AssertionError):attest_completion(area,writers,native,snapshot)
        expired=json.loads(json.dumps(snapshot));expired['elapsed']=15
        with self.assertRaises(AssertionError):attest_completion(private,writers,native,expired)
        for label,key,value in [('nan-stamp','monotonic',float('nan')),('infinite-stamp','monotonic',float('inf')),
                ('negative-infinite-stamp','monotonic',float('-inf')),('future-stamp','monotonic',time.monotonic()+60),
                ('nan-elapsed','elapsed',float('nan')),('infinite-elapsed','elapsed',float('inf'))]:
            malformed=json.loads(json.dumps(snapshot));malformed[key]=value
            with self.subTest(deadline=label),self.assertRaises(AssertionError):attest_completion(private,writers,native,malformed)
        for condition in ('live','zombie','reused'):
            wrong=json.loads(json.dumps(snapshot));wrong['processes']['observer']['state']=condition
            with self.subTest(lifetime=condition),self.assertRaises(AssertionError):attest_completion(private,writers,native,wrong)

    def test_real_zombie_and_reused_identity_do_not_count_as_absent(self):
        pid=os.fork()
        if pid==0:os._exit(0)
        try:
            # Capture real startticks before /proc removes it; a zombie is still
            # the original kernel, independent of unreadable zombie executable.
            deadline=time.monotonic()+5
            while True:
                parts=(Path('/proc')/str(pid)/'stat').read_text().split(') ')[1].split()
                if parts[0]=='Z':break
                self.assertLess(time.monotonic(),deadline);time.sleep(.01)
            self.assertEqual(probe({'pid':pid,'starttime':parts[19]})['state'],'zombie')
            self.assertEqual(probe({'pid':pid,'starttime':'0'})['state'],'reused')
        finally:os.waitpid(pid,0)
        self.assertEqual(probe({'pid':pid,'starttime':parts[19]})['state'],'absent')

if __name__=='__main__':unittest.main()
