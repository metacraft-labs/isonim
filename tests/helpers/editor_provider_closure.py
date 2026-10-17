"""Independent host completion after actual owned writer/native quiescence.

No fabricated child exit/reader join. Child-finally and host-quiescence origins
are distinct. Host sealing requires independently captured host identities and
actual durable per-frame progress/error receipts, never a bare trace snapshot.
"""
import hashlib
import base64
import json
import math
import os
from pathlib import Path
import time

def digest(data):return hashlib.sha256(data).hexdigest()
def identity(pid):
    proc=Path('/proc')/str(pid);parts=(proc/'stat').read_text().split(') ')[1].split()
    return {'pid':pid,'starttime':parts[19],'executable':os.readlink(proc/'exe'),'loadedSha256':digest((proc/'exe').read_bytes()),
        'namespacePids':[int(value) for value in next(line for line in (proc/'status').read_text().splitlines() if line.startswith('NSpid:')).split()[1:]]}
def probe(original):
    try:
        proc=Path('/proc')/str(original['pid']);parts=(proc/'stat').read_text().split(') ')[1].split();start=parts[19];status=parts[0]
        state='reused' if start!=original['starttime'] else 'zombie' if status=='Z' else 'live'
        try:exe=os.readlink(proc/'exe')
        except FileNotFoundError:exe=None
        return {'pid':original['pid'],'originalStarttime':original['starttime'],'observedStarttime':start,'status':status,'state':state,'executable':exe}
    except (FileNotFoundError,ProcessLookupError):return {'pid':original['pid'],'originalStarttime':original['starttime'],'state':'absent'}
def capture_writers(runtime):
    launch=json.loads((runtime.artifacts/'real-provider-launch.json').read_text());table=runtime.observer.snapshot();owned={runtime.server.pid,runtime.harborPid}
    while True:
        added={pid for pid,row in table.items() if row[0] in owned}-owned
        if not added:break
        owned.update(added)
    result={}
    for label,key in [('observer','observer_pid'),('acp','provider_pid')]:
        matches=[]
        for pid in owned:
            try:
                proc=Path('/proc')/str(pid);names=[int(value) for value in next(line for line in (proc/'status').read_text().splitlines() if line.startswith('NSpid:')).split()[1:]]
                if names[-1]==launch[key]:matches.append(identity(pid))
            except (FileNotFoundError,ProcessLookupError,StopIteration):continue
        if len(matches)!=1:raise AssertionError('Exact owning host writer namespace mapping required: '+label)
        result[label]=matches[0]
    return result

def authenticate_progress(private,writer):
    private=Path(private);progress=json.loads((private/'provider-wire-progress.json').read_text())
    if progress.get('origin')!='observer-progress' or progress.get('complete') is not False or progress.get('errors')!=[]:raise AssertionError('Actual clean incomplete progress receipt required')
    expected={'namespacePid':writer['namespacePids'][-1],'starttime':writer['starttime'],'loadedSha256':writer['loadedSha256']}
    if progress.get('writer')!=expected:raise AssertionError('Original progress writer identity mismatch')
    trace=(private/'real-provider-wire.jsonl').read_bytes();receipt_data=(private/'provider-wire-receipts.jsonl').read_bytes()
    if not trace or not trace.endswith(b'\n') or not receipt_data.endswith(b'\n'):raise AssertionError('Complete actual trace/receipt lines required')
    if progress.get('traceBytes')!=len(trace) or progress.get('traceSha256')!=digest(trace) or progress.get('receiptsSha256')!=digest(receipt_data):raise AssertionError('Durable progress/trace/receipt mismatch')
    lines=trace.splitlines(keepends=True);receipts=[json.loads(line) for line in receipt_data.splitlines()]
    if type(progress.get('frames')) is not int or progress['frames']!=len(lines) or len(receipts)!=len(lines):raise AssertionError('Exact durable frame counts required')
    chain='0'*64;counts={'request':0,'response':0};forwarded={direction:bytearray() for direction in counts}
    for order,(line,item) in enumerate(zip(lines,receipts)):
        row=json.loads(line);direction=row['direction']
        if direction not in counts or type(row.get('message')) is not dict:raise AssertionError('Actual structured frame required')
        if type(item.get('order')) is not int or item.get('order')!=order or item.get('direction')!=direction or item.get('traceLineSha256')!=digest(line) or item.get('previousChain')!=chain or item.get('completeLine') is not True:raise AssertionError('Exact ordered complete frame receipt required')
        if type(item.get('wireFrameBytes')) is not int or item['wireFrameBytes']<=0 or type(item.get('wireFrameSha256')) is not str or len(item['wireFrameSha256'])!=64:raise AssertionError('Actual original-byte write receipt required')
        raw=base64.b64decode(item.get('privateWireFrameBase64',''),validate=True)
        if len(raw)!=item['wireFrameBytes'] or digest(raw)!=item['wireFrameSha256'] or not raw.endswith(b'\n') or json.loads(raw)!=row['message']:raise AssertionError('Exact actual forwarded bytes/frame digest required')
        content={key:value for key,value in item.items() if key!='chain'};chain=digest(json.dumps(content,sort_keys=True).encode())
        if item.get('chain')!=chain:raise AssertionError('Durable receipt chain mismatch')
        counts[direction]+=1;forwarded[direction].extend(raw)
    if progress.get('chain')!=chain or progress.get('counts')!=counts or any(type(value) is not int for value in progress.get('counts',{}).values()):raise AssertionError('Exact final progress chain/counts required')
    observed=progress.get('ingress')
    if type(observed) is not dict or type(observed.get('schema')) is not int or observed['schema']!=1:raise AssertionError('Durable observed ingress required')
    journal=(private/'provider-wire-ingress.jsonl').read_bytes()
    if not journal or not journal.endswith(b'\n') or observed.get('journalSha256')!=digest(journal):raise AssertionError('Complete observed ingress journal required')
    chunks=[json.loads(line) for line in journal.splitlines()];streams={direction:bytearray() for direction in counts};chain='0'*64
    if type(observed.get('chunks')) is not int or observed['chunks']!=len(chunks):raise AssertionError('Exact observed ingress chunk count required')
    for order,item in enumerate(chunks):
        direction=item.get('direction')
        if type(item.get('order')) is not int or item['order']!=order or direction not in streams or item.get('previousChain')!=chain:raise AssertionError('Exact ordered ingress chunks required')
        raw=base64.b64decode(item.get('privateBytesBase64',''),validate=True)
        if type(item.get('bytes')) is not int or item['bytes']<=0 or item['bytes']!=len(raw) or item.get('sha256')!=digest(raw):raise AssertionError('Exact observed ingress bytes required')
        chain=digest(json.dumps({key:value for key,value in item.items() if key!='chain'},sort_keys=True).encode())
        if item.get('chain')!=chain:raise AssertionError('Exact observed ingress chain required')
        streams[direction].extend(raw)
    if observed.get('chain')!=chain or type(observed.get('directions')) is not dict or set(observed['directions'])!=set(streams):raise AssertionError('Exact final observed ingress chain/directions required')
    for direction,raw in streams.items():
        evidence=observed['directions'][direction]
        expected={'observedBytes':len(raw),'observedSha256':digest(raw),'forwardedBytes':len(forwarded[direction]),
            'forwardedSha256':digest(forwarded[direction]),'unforwardedBytes':len(raw)-len(forwarded[direction])}
        if type(evidence) is not dict or evidence!=expected or any(type(evidence.get(key)) is not int for key in ['observedBytes','forwardedBytes','unforwardedBytes']):raise AssertionError('Exact observed/forwarded directional bytes required')
        if raw!=forwarded[direction] or evidence['unforwardedBytes']!=0:raise AssertionError('Observed incomplete or unforwarded ingress rejects completion')
    return progress

def attest_completion(private,writers,native,snapshot):
    if set(writers)!={'observer','acp'}:raise AssertionError('Both actual writer identities required')
    if set(snapshot['processes'])!={'observer','acp','native'} or any(snapshot['processes'][label]['state']!='absent' for label in writers) or snapshot['processes']['native']['state'] not in ('absent','reused'):raise AssertionError('Original writers absent and native reaped required; live/zombie/wrong writer reject')
    for label,original in {**writers,'native':native}.items():
        if probe(original)['state'] not in (('absent','reused') if label=='native' else ('absent',)):raise AssertionError('Independent original process still exists or writer identity reused')
        point=snapshot['processes'][label]
        if point.get('pid')!=original['pid'] or point.get('originalStarttime')!=original['starttime']:raise AssertionError('Original lifetime receipt identity mismatch')
    elapsed=snapshot.get('elapsed');stamp=snapshot.get('monotonic')
    if type(elapsed) not in (int,float) or type(stamp) not in (int,float) or not math.isfinite(elapsed) or not math.isfinite(stamp) or not 0<=elapsed<15 or stamp>time.monotonic():raise AssertionError('Original15s actual receipt deadline required')
    deadline=stamp+15-elapsed
    def within_bound():
        if time.monotonic()>=deadline:raise AssertionError('Original15s completed authenticated recorder deadline exceeded')
    within_bound()
    progress=authenticate_progress(private,writers['observer']);file=Path(private)/'provider-wire-state.json'
    within_bound()
    if file.exists():
        state=json.loads(file.read_text())
        if state.get('origin')!='child-finally' or state.get('complete') is not True or state.get('errors')!=[] or state.get('traceSha256')!=progress['traceSha256'] or state.get('writer')!=progress['writer']:raise AssertionError('Genuine completed child receipt invalid')
        if type(state.get('providerExit')) is not int or type(state.get('requestReaderAliveAtProviderExit')) is not bool or state.get('providerPid')!=writers['acp']['namespacePids'][-1] or state.get('observerPid')!=writers['observer']['namespacePids'][-1]:raise AssertionError('Actual child exit/reader/namespace receipt required')
        within_bound();return state
    state={'origin':'host-quiescence','complete':True,'errors':[],'traceSha256':progress['traceSha256'],'counts':progress['counts'],'writer':progress['writer'],
        'providerExit':None,'requestReaderAliveAtProviderExit':None,'childFinallyObserved':False,'writers':writers,'native':native,'completionProbe':snapshot,'progressChain':progress['chain']}
    fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as output:json.dump(state,output);output.flush();os.fsync(output.fileno())
    within_bound()
    return state

def wait_completion(private,writers,native,filename):
    # SAME original15s bound. Every actual PID/status sample is retained even on
    # timeout/error; no finally kill, extra allowance or child-success invention.
    started=time.monotonic();snapshots=[]
    while time.monotonic()-started<15:
        snapshot={'monotonic':time.monotonic(),'elapsed':time.monotonic()-started,'processes':{label:probe(point) for label,point in {**writers,'native':native}.items()},'childReceiptExists':(Path(private)/'provider-wire-state.json').exists()}
        snapshots.append(snapshot)
        fd=os.open(filename,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as output:json.dump({'boundSeconds':15,'snapshots':snapshots},output)
        if all(snapshot['processes'][label]['state']=='absent' for label in writers) and snapshot['processes']['native']['state'] in ('absent','reused'):return attest_completion(private,writers,native,snapshot)
        time.sleep(.03)
    raise AssertionError('Original15s actual kernel/writers/completed recorder conjunction failed')
