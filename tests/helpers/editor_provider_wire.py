"""Transparent private ACP wire/lifecycle recorder, no substitute responses.

Real bytes pass unchanged; the opt-in official scenario route substitutes only
model decisions. Both real and playback provider processes/ACKs remain actual.
"""
import json
import base64
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

def observe_provider(root, provider, argv, env=None):
    private = root/'private'
    trace_path = private / 'real-provider-wire.jsonl'
    trace_fd = os.open(trace_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    trace = os.fdopen(trace_fd, 'w')
    lock = threading.Lock()
    errors=[];counts={'request':0,'response':0}
    receipts_path=private/'provider-wire-receipts.jsonl'
    receipts=os.fdopen(os.open(receipts_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w')
    start=Path('/proc/self/stat').read_text().split(') ')[1].split()[19]
    writer={'namespacePid':os.getpid(),'starttime':start,'loadedSha256':hashlib.sha256(Path('/proc/self/exe').read_bytes()).hexdigest()}
    chain='0'*64;frames=0;entries=[];trace_hash=hashlib.sha256();receipt_hash=hashlib.sha256();trace_bytes=0
    ingress=os.fdopen(os.open(private/'provider-wire-ingress.jsonl',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w')
    ingress_hash=hashlib.sha256();ingress_chain='0'*64;ingress_chunks=0
    observed={direction:{'bytes':0,'hash':hashlib.sha256()} for direction in counts}
    forwarded={direction:{'bytes':0,'hash':hashlib.sha256()} for direction in counts}
    def progress():
        trace.flush();os.fsync(trace.fileno());receipts.flush();os.fsync(receipts.fileno());ingress.flush();os.fsync(ingress.fileno())
        state={'origin':'observer-progress','writer':writer,'complete':False,'frames':frames,'chain':chain,'errors':list(errors),'counts':dict(counts),
            'traceBytes':trace_bytes,'traceSha256':trace_hash.hexdigest(),
            'receiptsSha256':receipt_hash.hexdigest(),
            'ingress':{'schema':1,'chunks':ingress_chunks,'chain':ingress_chain,'journalSha256':ingress_hash.hexdigest(),
                'directions':{direction:{'observedBytes':observed[direction]['bytes'],'observedSha256':observed[direction]['hash'].hexdigest(),
                    'forwardedBytes':forwarded[direction]['bytes'],'forwardedSha256':forwarded[direction]['hash'].hexdigest(),
                    'unforwardedBytes':observed[direction]['bytes']-forwarded[direction]['bytes']} for direction in counts}}}
        pending=private/'provider-wire-progress.pending'
        fd=os.open(pending,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as output:json.dump(state,output);output.flush();os.fsync(output.fileno())
        os.replace(pending,private/'provider-wire-progress.json')
    def observe(direction,chunk):
        # Raw os.read in BOTH directions avoids BufferedReader read-ahead hiding
        # an unfinished line. Journal every returned chunk before parsing or
        # forwarding; a complete prefix cannot erase a consumed fragment.
        # read(2) and fsync cannot be atomic: death between return and publication
        # is outside this userspace attestation, not invented durable evidence.
        nonlocal ingress_chain,ingress_chunks
        with lock:
            item={'order':ingress_chunks,'direction':direction,'bytes':len(chunk),'sha256':hashlib.sha256(chunk).hexdigest(),
                'privateBytesBase64':base64.b64encode(chunk).decode(),'previousChain':ingress_chain}
            ingress_chain=hashlib.sha256(json.dumps(item,sort_keys=True).encode()).hexdigest();item['chain']=ingress_chain
            encoded=(json.dumps(item)+'\n').encode();ingress.write(encoded.decode());ingress_hash.update(encoded);ingress_chunks+=1
            observed[direction]['bytes']+=len(chunk);observed[direction]['hash'].update(chunk)
            progress()

    def failure(where,error):
        with lock:
            errors.append({'where':where,'type':type(error).__name__,'messageSha256':hashlib.sha256(str(error).encode()).hexdigest()});progress()
    child = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    (root / 'real-provider-launch.json').write_text(json.dumps({
        'observer_pid': os.getpid(), 'provider_pid': child.pid,
        'provider': str(provider), 'cwd': os.getcwd()}))

    def record(direction,line,forward):
        nonlocal chain,frames,trace_bytes
        if not line.endswith(b'\n'):
            failure('frame-eof-'+direction,ValueError('Incomplete frame at EOF'))
        try:message=json.loads(line)
        except (ValueError,UnicodeError) as error:
            failure('parser-'+direction,error);forward();return
        with lock:
            encoded=(json.dumps({'direction':direction,'message':message})+'\n').encode()
            trace.write(encoded.decode());trace.flush();os.fsync(trace.fileno());trace_hash.update(encoded);trace_bytes+=len(encoded)
            entry={'order':len(entries),'direction':direction,'traceLineSha256':hashlib.sha256(encoded).hexdigest(),'wireFrameSha256':hashlib.sha256(line).hexdigest(),'wireFrameBytes':len(line),'privateWireFrameBase64':base64.b64encode(line).decode(),'completeLine':line.endswith(b'\n')}
            entries.append({'receipt':entry,'forwarded':False})
        # NEVER hold the shared evidence lock over either original pipe write.
        # The other direction must drain independently under real backpressure.
        forward()
        with lock:
            entries[entry['order']]['forwarded']=True
            # Commit only the contiguous trace-order prefix. An unfinished write
            # cannot gain a completed receipt through another direction's write.
            while frames<len(entries) and entries[frames]['forwarded']:
                item={**entries[frames]['receipt'],'previousChain':chain}
                chain=hashlib.sha256(json.dumps(item,sort_keys=True).encode()).hexdigest();item['chain']=chain
                receipt=(json.dumps(item)+'\n').encode();receipts.write(receipt.decode());receipt_hash.update(receipt);frames+=1;counts[item['direction']]+=1
                raw=base64.b64decode(item['privateWireFrameBase64']);forwarded[item['direction']]['bytes']+=len(raw);forwarded[item['direction']]['hash'].update(raw)
            progress()

    def input_loop():
        try:
            pending = b''
            while True:
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk: break
                observe('request',chunk)
                pending += chunk
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    def send():child.stdin.write(line+b'\n');child.stdin.flush()
                    record('request',line+b'\n',send)
            if pending:failure('request-eof',ValueError('Incomplete request line'))
        except BrokenPipeError:
            pass # Original provider close can race with the original stdin writer.
        except BaseException as error:
            failure('request-reader',error)
        finally:
            child.stdin.close()
            if child.poll() is None: child.terminate()

    def forward(signum, _frame):
        if child.poll() is None: child.send_signal(signum)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    reader = threading.Thread(target=input_loop, daemon=True)
    reader.start()
    try:
        pending=b''
        while True:
            chunk=os.read(child.stdout.fileno(),65536)
            if not chunk:break
            observe('response',chunk);pending+=chunk
            while b'\n' in pending:
                line,pending=pending.split(b'\n',1);line+=b'\n'
                def send():sys.stdout.buffer.write(line);sys.stdout.buffer.flush()
                record('response',line,send)
        if pending:
            # Preserve original iteration's final unterminated output forwarding,
            # but the consumed fragment and EOF error make completion reject.
            line=pending
            def send():sys.stdout.buffer.write(line);sys.stdout.buffer.flush()
            record('response',line,send)
    except BaseException as error:
        failure('response-reader',error);raise
    finally:
        if child.poll() is None: child.terminate()
        result = child.wait()
        child.stdout.close()
        with lock:progress()
        trace.close();receipts.close();ingress.close()
        state={'origin':'child-finally','complete':True,'writer':writer,'errors':errors,'counts':counts,'traceSha256':hashlib.sha256(trace_path.read_bytes()).hexdigest(),'providerPid':child.pid,'observerPid':os.getpid(),'providerExit':result,'requestReaderAliveAtProviderExit':reader.is_alive()}
        fd=os.open(private/'provider-wire-state.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as output:json.dump(state,output);output.flush();os.fsync(output.fileno())
    return result if result >= 0 else 128 - result
