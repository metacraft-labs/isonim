#!/usr/bin/env python3
"""Real native daemon, HTTP, stdio ACP process and shutdown exit status.

A scripted external ACP agent substitutes provider protocol behavior and model
output at the provider boundary. Production native transport/client, CLI, control
registry, files, event delivery and shutdown are real. This isolates deterministic
ownership checks from an external model/service and leaves two live sessions open
when the daemon receives SIGTERM. Registration uses a minimal fixture snapshot
because this test isolates ownership; the registered source GUI suite exercises
actual mounted views, state snapshots and renderer integration.
"""
import http.client,json,os,sys,queue,signal,subprocess,tempfile,threading,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

class NativeAcpShutdown(unittest.TestCase):
    def test_idle_live_acp_session_shuts_down_with_clean_native_exit(self):
        with tempfile.TemporaryDirectory(prefix='isonim-acp-shutdown-') as temp:
            root=Path(temp).resolve(); config=root/'agent.toml'
            previous_environments=set((root/('Library/Application Support' if sys.platform=='darwin' else '.local/share')/'isonim/editor-control').glob('isonim-control-*/environment.json'))
            config.write_text('[agent]\nbackend="custom"\ncommand="python3"\nargs='+json.dumps([str(ROOT/'tests/helpers/editor_control_peer.py')])+'\nprimer_enabled=false\n')
            daemon=subprocess.Popen([str(ROOT/'build/bin/isonim-review'),'serve','--agent-routes-only','--port','0','--bind','127.0.0.1','--workspace',str(root),'--config',str(config)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True,start_new_session=True,env={**os.environ,'HOME':str(root),'ISONIM_EDITOR_BROWSER_BOOTSTRAP':'isolated-shutdown-bootstrap','CONTROL_PROBE_DIR':str(root)})
            lines=queue.Queue(); log=[]
            def drain():
                for line in daemon.stderr:
                    log.append(line);lines.put(line)
            reader=threading.Thread(target=drain,daemon=True);reader.start()
            try:
                while True:
                    line=lines.get(timeout=30)
                    if line.startswith('READY '):
                        port=int(line.split()[1]);break
                    self.assertIsNone(daemon.poll(),''.join(log))
                def rpc(method,params,token):
                    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
                    connection.request('POST','/api/editor/rpc',json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}),{'Content-Type':'application/json','X-IsoNim-Control':token})
                    response=connection.getresponse();result=json.loads(response.read());connection.close()
                    self.assertNotIn('error',result)
                    return result['result']
                scope=rpc('editor.register',{'workspace':'native-shutdown','state':{'revision':0}},'isolated-shutdown-bootstrap')
                target={key:scope[key] for key in ('workspace','instance','epoch')}
                for _ in range(2):
                    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
                    connection.request('POST','/api/agent/sessions',json.dumps({'editor':target}),{'Content-Type':'application/json','X-IsoNim-Control':scope['browserToken']})
                    response=connection.getresponse();self.assertEqual(response.status,200)
                    session=json.loads(response.read())['sessionId'];connection.close()
                    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
                    connection.request('POST','/api/agent/prompts',json.dumps({'sessionId':session,'messages':[{'role':'user','content':[{'type':'text','text':'Complete one turn and remain available.'}]}]}),{'Content-Type':'application/json','Connection':'close'})
                    response=connection.getresponse();self.assertEqual(response.status,200)
                    stream=response.read().decode();connection.close()
                    self.assertIn('CONTROL_SCOPE_OK',stream);self.assertIn('event: end',stream)
                providers=[]
                for row in subprocess.check_output(['ps','-eo','pid=,ppid=,args='],text=True).splitlines():
                    fields=row.split(None,2)
                    if len(fields)==3 and int(fields[1])==daemon.pid and str(ROOT/'tests/helpers/editor_control_peer.py') in fields[2]: providers.append(int(fields[0]))
                self.assertEqual(len(providers),2,'Two actual initialized stdio provider processes must remain available')
                environments=[]
                for environment in set((root/('Library/Application Support' if sys.platform=='darwin' else '.local/share')/'isonim/editor-control').glob('isonim-control-*/environment.json'))-previous_environments:
                    payload=json.loads(environment.read_text())
                    if payload.get('ISONIM_EDITOR_INSTANCE')==scope['instance']: environments.append((environment,payload))
                self.assertEqual(len(environments),2,'Actual scoped native launch creates two private environment files')
                for index,(environment,payload) in enumerate(environments):
                    token=payload['ISONIM_EDITOR_TOKEN']
                    for number in range(10):
                        operation=rpc('editor.command',{**target,'commandId':f'owned-{index}-{number}','command':'viewport','viewport':'wide','expectedRevision':0},token)
                        self.assertEqual(operation['status'],'queued')
                daemon.send_signal(signal.SIGTERM)
                self.assertEqual(daemon.wait(timeout=10),0,''.join(log))
                reader.join(timeout=5)
                self.assertFalse(reader.is_alive(),'Native daemon stderr did not close')
                self.assertNotIn('SIGSEGV',''.join(log))
                for pid in providers:
                    with self.assertRaises(ProcessLookupError): os.kill(pid,0)
                for environment,_ in environments: self.assertFalse(environment.exists(),'Native shutdown must remove private scoped environment')
            finally:
                if daemon.poll() is None: os.killpg(daemon.pid,signal.SIGKILL);daemon.wait(timeout=5)
                reader.join(timeout=5)
                daemon.stderr.close()

if __name__=='__main__':unittest.main()
