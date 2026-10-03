"""Fail-closed capture inventory guards shared by driver, comparator and tests."""
import hashlib, json, pathlib, struct, datetime, zlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
IMAGE='mcr.microsoft.com/playwright@sha256:eac9b0a5312cdab40ee8c2429df5bf19bffdccf8f3bf3c42268e173f97541645'
FLAGS=['--no-sandbox','--disable-gpu','--force-color-profile=srgb','--font-render-hinting=none','--disable-lcd-text']
SIZES={'wide':{'width':1440,'height':900,'panel':420},'narrow':{'width':1024,'height':768,'panel':240}}
SCOPE='actual production conversation scroll surface; excludes editor chrome, preview and composer'
ENV={'deviceScaleFactor':1,'locale':'en-US','timezoneId':'UTC','colorScheme':'dark','reducedMotion':'reduce'}
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def require(condition,message):
    if not condition:raise ValueError(message)
def sha(value):return isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)
def definitions():
    expected=json.loads((ROOT/'tools/chat-visual-expected.json').read_text()); thresholds=json.loads((ROOT/'tools/chat-visual-thresholds.json').read_text())
    require(expected and set(expected)==set(thresholds),'expected/threshold inventory mismatch')
    require(all(isinstance(x,list) and x and all(isinstance(v,str) and v.strip() for v in x) for x in expected.values()),'empty expected elements')
    require(all(type(v) in (int,float) and 0<=v<1 for v in thresholds.values()),'invalid thresholds')
    return expected,thresholds
def png(path):
    raw=path.read_bytes();require(raw[:8]==b'\x89PNG\r\n\x1a\n' and raw[12:16]==b'IHDR','not PNG')
    width,height,depth,kind,compression,filtering,interlace=struct.unpack('>IIBBBBB',raw[16:29])
    require(0<width<=2000 and 0<height<=1200 and depth==8 and kind in (2,6) and (compression,filtering,interlace)==(0,0,0),'unsupported PNG dimensions/format')
    position=8;blocks=[];ended=False
    while position<len(raw):
        require(position+12<=len(raw),'truncated PNG chunk');length=struct.unpack('>I',raw[position:position+4])[0];tag=raw[position+4:position+8];data=raw[position+8:position+8+length]
        require(position+length+12<=len(raw),'truncated PNG payload');crc=struct.unpack('>I',raw[position+8+length:position+12+length])[0]
        require(zlib.crc32(tag+data)&0xffffffff==crc,'PNG CRC invalid');position+=length+12
        if tag==b'IDAT':blocks.append(data)
        if tag==b'IEND':ended=True;break
    require(ended and position==len(raw) and blocks,'incomplete PNG')
    inflated=zlib.decompress(b''.join(blocks));channels=3 if kind==2 else 4
    require(len(inflated)==height*(1+width*channels),'invalid PNG scanlines')
    require(all(inflated[row*(1+width*channels)]<=4 for row in range(height)),'invalid PNG row filter')
    return width,height
def guard(directory,canary=False,current=False):
    directory=pathlib.Path(directory);m=json.loads((directory/'manifest.json').read_text());expected,thresholds=definitions()
    keys={(v,s) for v in (['conversation','plan'] if canary else expected) for s in SIZES}
    require(m.get('schema')==2 and m.get('container')==IMAGE and m.get('flags')==FLAGS and m.get('environment')==ENV and m.get('sizes')==SIZES,'capture runtime configuration mismatch')
    lineage=m.get('lineage',{});required=['bundleSha256','sceneSha256','captureSha256','horizontalGuardSha256','expectedSha256','thresholdsSha256','browserExecutableSha256']
    require(all(sha(lineage.get(k)) for k in required),'missing source/browser lineage')
    fonts=lineage.get('fonts');require(isinstance(fonts,list) and len(fonts)==48 and len({f.get('file') for f in fonts})==48 and all(f.get('file') and sha(f.get('sha256')) for f in fonts),'font inventory invalid')
    runtime=json.loads((ROOT/'tools/chat-visual-runtime.json').read_text())
    require(m.get('browser')==runtime['browser'] and m.get('node')==runtime['node'] and lineage['fonts']==runtime['fonts'] and lineage['browserExecutableSha256']==runtime['browserExecutableSha256'],'pinned browser/node/font runtime changed')
    assets=lineage.get('mountedAssets',[]);require([x.get('file') for x in assets]==['editor.js','index.html','fabric.min.js','paper-core.min.js','svgo.browser.js'] and all(sha(x.get('sha256')) for x in assets),'mounted asset inventory incomplete')
    if current:
        for asset in assets:require(asset['sha256']==digest(ROOT/'build/editor-chat'/asset['file']),'stale mounted assets; full regeneration required')
        inputs={'bundleSha256':'build/editor-chat/editor.js','sceneSha256':'tests/scenarios/chat-activity/public-session-events.json','captureSha256':'tools/chat-visual-campaign.mjs','horizontalGuardSha256':'tools/chat-horizontal-guard.mjs','expectedSha256':'tools/chat-visual-expected.json','thresholdsSha256':'tools/chat-visual-thresholds.json'}
        for key,file in inputs.items():require(lineage[key]==digest(ROOT/file),f'stale source closure: {key}; full regeneration required')
    rows=m.get('views');require(isinstance(rows,list) and rows,'empty capture inventory')
    seen=set()
    for row in rows:
        key=(row.get('view'),row.get('size'));require(key in keys and key not in seen,'unknown or duplicate view');seen.add(key)
        require(row.get('file')==f'{key[0]}-{key[1]}.png','unexpected capture path')
        file=directory/row['file'];require(file.is_file() and digest(file)==row.get('sha256'),'missing or tampered capture PNG')
        dimensions=png(file);require(row.get('dimensions')==list(dimensions),'PNG dimensions differ from manifest')
        require(row.get('browser')==m['browser'],'row browser mismatch')
        ready=row.get('sceneReadiness',{});state=ready.get('state',{})
        require(ready.get('documentReadyState')=='complete' and ready.get('fontStatus')=='loaded' and ready.get('previewReadyState')=='complete' and ready.get('previewFontStatus')=='loaded' and ready.get('previewTitle')=='Chat preview' and ready.get('previewHeading')=='Website preview','missing mounted preview readiness')
        require(state.get('workspace')=='chat-acceptance' and state.get('storyId') in ('Pages / Home','Pages / Details'),'wrong selected preview readiness')
        require({'primary','secondary'}.issubset(ready.get('sceneGraphRows',[])) and {'primary','secondary'}.issubset(x.get('id') for x in state.get('elements',[])),'missing published scene rows')
        frames=ready.get('frameTimes',[]);require(len(frames)==2 and all(type(t) in (int,float) for t in frames) and frames[1]>frames[0],'missing normal readiness frames')
        require(row.get('perceptualThreshold')=={'maximumChangedPixelRatio':thresholds[key[0]]},'threshold mismatch')
        if canary:
            require(row.get('scope')==SCOPE and row.get('contentVerified') is True and row.get('events') and dimensions[0]>100 and dimensions[1]>100,'empty or wrong canary scope/content')
            control=row.get('positiveControl',{});cf=directory/f'{key[0]}-{key[1]}-positive-control.png'
            require(cf.is_file() and digest(cf)==control.get('changedSha256') and png(cf)==dimensions,'missing/tampered mutation control')
            try:exact_bytes(cf.read_bytes(),file.read_bytes())
            except ValueError:pass
            else:raise ValueError('canary mutation guard failed')
        else:require(row.get('scope')=='full editor viewport' and dimensions==(SIZES[key[1]]['width'],SIZES[key[1]]['height']),'full viewport scope mismatch')
    require(seen==keys,'missing required capture views')
    return m

def exact_bytes(first,second):
    require(first==second,'exact image mismatch')

def exact_canary(first,second):
    a=guard(first,True,True);b=guard(second,True,True)
    require({k:v for k,v in a.items() if k!='views'}=={k:v for k,v in b.items() if k!='views'},'canary lineage mismatch')
    aa={(v['view'],v['size']):v for v in a['views']};bb={(v['view'],v['size']):v for v in b['views']}
    for k,v in aa.items():exact_bytes((pathlib.Path(first)/v['file']).read_bytes(),(pathlib.Path(second)/bb[k]['file']).read_bytes())
    return a

def accepted(manifest):
    record=manifest.get('humanAcceptance',{})
    require(isinstance(record,dict) and record.get('decision')=='accepted' and all(isinstance(record.get(k),str) and record[k].strip() for k in ['reviewer','reviewedAt','evidence']),'meaningful human acceptance missing')
    try:when=datetime.datetime.fromisoformat(record['reviewedAt'].replace('Z','+00:00'))
    except ValueError:raise ValueError('acceptance timestamp invalid')
    require(when.tzinfo is not None,'acceptance timestamp needs timezone')
    require(record.get('reviewedViews')==sorted(v['view']+'/'+v['size'] for v in manifest['views']) and type(record.get('unresolvedP1P2')) is int and record.get('unresolvedP1P2')==0,'acceptance must cover every view with zero unresolved P1/P2')
    payload={k:v for k,v in manifest.items() if k!='humanAcceptance'}
    require(record.get('manifestSha256')==hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'acceptance not bound to manifest')
    require(not record.get('testOnly'),'test-only acceptance cannot pass real campaign')
