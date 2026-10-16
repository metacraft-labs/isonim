#!/usr/bin/env python3
"""Pinned production captures; strict canary first, reproducible review artifacts.
Human approval is never generated. Targeted updates require unchanged capture
closure and full existing inventory. Findings survive with stale review invalidated.
"""
import argparse, html, json, os, pathlib, subprocess, uuid
from chat_visual_guard import IMAGE, guard, exact_canary, definitions, digest, require

def artifacts(corpus, prior=None, invalidate=False):
    m=guard(corpus,current=True);expected,_=definitions();prior=prior or {};old=prior.get('views',{})
    rows={};sections=[]
    for v in m['views']:
        key=v['view']+'/'+v['size'];previous=old.get(key,{})
        same=not invalidate and previous.get('sha256')==v['sha256'] and prior.get('lineage')==m['lineage']
        rows[key]={'sha256':v['sha256'],'status':previous.get('status','pending-independent-review') if same else 'pending-independent-review','findings':previous.get('findings',[]),'history':previous.get('history',[])}
        if previous and not same:rows[key]['history'].append({'previousSha256':previous.get('sha256'),'previousStatus':previous.get('status'),'reason':'capture changed; prior review invalidated'})
        sections.append('<section id="'+html.escape(key)+'"><h2>'+html.escape(key)+'</h2><ul>'+''.join('<li>'+html.escape(e)+'</li>' for e in expected[v['view']])+'</ul><img src="'+html.escape(v['file'])+'" alt="'+html.escape(key)+'"></section>')
    ledger={'status':'pending-independent-adversarial-and-human-review','lineage':m['lineage'],'views':rows,'history':prior.get('history',[])}
    (corpus/'findings-ledger.json').write_text(json.dumps(ledger,indent=2)+'\n')
    (corpus/'review.html').write_text('<!doctype html><meta charset="utf-8"><title>IsoNim chat review candidate</title><style>body{background:#171923;color:#eee;font:16px sans-serif}img{max-width:100%}section{margin:40px 0}</style><h1>Pending independent and human review</h1>'+''.join(sections)+'<h2>Expected-elements detection control</h2><p>Apply the empty/wide expected-elements brief before aesthetic review.</p><img src="positive-control-missing-composer.png" alt="Expected-elements detection control">')
    (corpus/'perceptual-gates.json').write_text(json.dumps({'status':'pending-human-baseline','views':[{'view':v['view'],'size':v['size'],'threshold':v['perceptualThreshold']} for v in m['views']]},indent=2)+'\n')

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--view');p.add_argument('--size');p.add_argument('--canary-only',action='store_true');a=p.parse_args()
    repo=pathlib.Path(__file__).resolve().parents[1];out=pathlib.Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
    for name in ['canary-proof.json','capture-receipts.json']:
        (out/name).unlink(missing_ok=True)
    receipts=[]
    def capture(target,extra):
        target.mkdir(parents=True,exist_ok=True);cid=out/('container-'+uuid.uuid4().hex+'.cid')
        command=['docker','run','--rm','--cidfile',str(cid),'--platform','linux/amd64','--network','none','--ipc','private','--shm-size','1g','--user',f'{os.getuid()}:{os.getgid()}','-e','HOME=/tmp','-v',f'{repo}:/workspace:ro','-v',f'{target}:/captures:rw','-w','/workspace',IMAGE,'node','tools/chat-visual-campaign.mjs','--output','/captures',*extra]
        subprocess.run(command,check=True);identity=cid.read_text().strip();require(len(identity)==64 and all(c in '0123456789abcdef' for c in identity),'missing actual Docker container identity')
        receipts.append({'containerId':identity,'command':command,'manifestSha256':digest(target/'manifest.json')})
    for run in ['canary-a','canary-b']:capture(out/run,['--canary'])
    first=exact_canary(out/'canary-a',out/'canary-b');require(receipts[0]['containerId']!=receipts[1]['containerId'],'canary containers reused')
    (out/'canary-proof.json').write_text(json.dumps({'status':'passed','container':IMAGE,'receipts':receipts,'exactViews':first['views'],'scope':'conversation and plan surfaces only; full-editor exact failures remain unresolved'},indent=2)+'\n')
    if a.canary_only:return
    corpus=out/'corpus';prior=json.loads((corpus/'findings-ledger.json').read_text()) if (corpus/'findings-ledger.json').exists() else None
    if prior and not (a.view or a.size):
        archive=out/('review-history-'+uuid.uuid4().hex+'.json');archive.write_text(json.dumps(prior,indent=2)+'\n')
    extra=['--missing-element-control']
    if a.view:extra+=['--view',a.view]
    if a.size:extra+=['--size',a.size]
    capture(corpus,extra);guard(corpus,current=True)
    require((corpus/'missing-element-control.json').is_file() and (corpus/'positive-control-missing-composer.png').is_file(),'missing required detection control; full regeneration required')
    artifacts(corpus,prior,invalidate=not (a.view or a.size))
    (out/'capture-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
if __name__=='__main__':main()
