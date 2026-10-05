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
RECOVERY_TYPES=['proxy_credential_rotated','proxy_rate_limit_absorbed','dispatcher_restarted','anti_halting_resume_confirmed','session_leadership_migrated']
RECOVERY_VISIBLE={
 'recovery-top':[('proxy_credential_rotated','Provider access recovered'),('proxy_credential_rotated','anthropic'),('proxy_credential_rotated','401'),('proxy_rate_limit_absorbed','Provider throttling recovered'),('proxy_rate_limit_absorbed','2'),('proxy_rate_limit_absorbed','1200')],
 'recovery':[('dispatcher_restarted','Agent restarted'),('dispatcher_restarted','2'),('anti_halting_resume_confirmed','Agent progress resumed'),('anti_halting_resume_confirmed','idle'),('session_leadership_migrated','Session moved to another executor'),('session_leadership_migrated','authoring-host'),('session_leadership_migrated','preview-host'),('session_leadership_migrated','linux'),('session_leadership_migrated','40')]
}
def companion_geometry(box,viewport,name):
    require(all(type(box.get(k)) in (int,float) for k in ['top','bottom','left','right','width','height']) and all(type(viewport.get(k)) in (int,float) for k in ['top','bottom','left','right']),f'missing {name} visible geometry')
    require(box['width']>0 and box['height']>0 and box['top']>=viewport['top']-1 and box['bottom']<=viewport['bottom']+1 and box['left']>=viewport['left']-1 and box['right']<=viewport['right']+1,f'{name} required content outside visible frame')
def companion_scroll(evidence,top,name):
    require(all(type(evidence.get(k)) in (int,float) for k in ['scrollTop','scrollHeight','clientHeight']),f'missing {name} scroll position')
    require(evidence['scrollTop']==0 if top else evidence['scrollTop']+evidence['clientHeight']>=evidence['scrollHeight']-2,f'wrong {name} scroll position')
def recovery_guard(row):
    evidence=row.get('recoveryEvidence',{});view=row['view']
    require(evidence.get('parent')=='recovery' and evidence.get('companion')=='recovery-top' and evidence.get('position')==('top' if view=='recovery-top' else 'bottom'),'missing/wrong recovery companion metadata')
    require(row.get('events')==RECOVERY_TYPES and [c.get('source') for c in evidence.get('cards',[])]==RECOVERY_TYPES,'recovery original events/cards changed')
    cards={c['source']:c.get('text','') for c in evidence['cards']}
    for source,text in RECOVERY_VISIBLE['recovery-top']+RECOVERY_VISIBLE['recovery']:
        require(text in cards[source],f'missing recovery card semantics: {text}')
    visible=evidence.get('visible',[])
    require([(v.get('source'),v.get('text')) for v in visible]==RECOVERY_VISIBLE[view],'missing recovery visible heading/facts')
    viewport=evidence.get('viewport',{})
    for v in visible:
        box=v.get('box',{})
        companion_geometry(box,viewport,'recovery')
    companion_scroll(evidence,view=='recovery-top','recovery')

LONG_IDENTIFIER='responsiveHeroWithSharedSpacingAndAccessiblePrimaryAction'*6
LONG_PROSE='Long source identifiers remain readable: '+LONG_IDENTIFIER
LONG_FINAL='setStyle(hero, "padding", "32px") # line 11'
LONG_VISIBLE={'long-content-top':[('log','Assistant'),('log',LONG_PROSE)],'long-content':[('tool_use','isonim inspect'),('tool_use','started'),('log',LONG_FINAL)]}
def long_content_guard(row):
    evidence=row.get('longContentEvidence',{});view=row['view'];top=view=='long-content-top'
    require(evidence.get('parent')=='long-content' and evidence.get('companion')=='long-content-top' and evidence.get('position')==('top' if top else 'bottom'),'missing/wrong long-content companion metadata')
    require(row.get('events')==['log','tool_use'] and [c.get('source') for c in evidence.get('cards',[])]==['log','tool_use'],'long-content original events/cards changed')
    cards=evidence['cards']
    require(all(t in cards[0].get('text','') for t in ['Assistant',LONG_PROSE,LONG_FINAL]) and all(t in cards[1].get('text','') for t in ['isonim inspect','started']),'missing long-content card semantics')
    visible=evidence.get('visible',[]);viewport=evidence.get('viewport',{})
    require([(v.get('source'),v.get('text')) for v in visible]==LONG_VISIBLE[view],'missing long-content visible heading/content')
    for v in visible:companion_geometry(v.get('box',{}),viewport,'long-content')
    if top:
        lines=evidence.get('identifierLines')
        require(isinstance(lines,list) and len(lines)>1,'long-content identifier not visibly wrapped')
        for box in lines:companion_geometry(box,viewport,'long-content identifier')
    else:require(evidence.get('identifierLines') is None,'wrong long-content bottom identifier evidence')
    companion_scroll(evidence,top,'long-content')

EXPANDED_CODE='\n'.join(f'setStyle(hero, "padding", "32px") # line {index}' for index in range(12))
def expanded_code_guard(row):
    evidence=row.get('expandedCodeEvidence') or {}
    require(row.get('events')==['log','tool_use'],'expanded-code original event sequence changed')
    require(evidence.get('exactText')==EXPANDED_CODE and evidence.get('language')=='nim','expanded-code exact full text/language missing')
    require(evidence.get('modal') is True and evidence.get('focus') is True and evidence.get('associated') is True and evidence.get('pageOverflow') is False,'expanded-code interaction/overflow evidence missing')
    viewport=evidence.get('viewport',{});dialog=evidence.get('dialog',{});code=evidence.get('code',{});original=evidence.get('original',{})
    companion_geometry(dialog,viewport,'expanded-code dialog');companion_geometry(code,dialog,'expanded-code area')
    require(type(original.get('width')) in (int,float) and type(original.get('height')) in (int,float) and code['width']>original['width']*1.5 and code['height']>original['height'],'expanded-code reading area is not larger')
    lines=evidence.get('lines',[]);require(len(lines)==12,'expanded-code full lines missing')
    for index,(line,literal) in enumerate(zip(lines,EXPANDED_CODE.split('\n'))):
        require(line.get('index')==index and line.get('text')==literal,'expanded-code ordered literal line identity missing')
        rects=line.get('rects',[]);require(bool(rects),'expanded-code line rectangles missing')
        for rect in rects:companion_geometry(rect,code,'expanded-code line')

def tool_code_details_guard(row):
    e=row.get('toolCodeDetailsEvidence') or {}
    require(row.get('events')==['tool_use','tool_result'],'tool-code-details real public event sequence missing')
    scenario=json.loads((ROOT/'tests/scenarios/chat-activity/code-reading.json').read_text())['publicTool']
    require(scenario['expectedFirst'] in e.get('exactText','') and scenario['expectedSecond'] in e.get('exactText',''),'tool-code-details complete safe text missing')
    require(e.get('label')=='Expand code block 2 · sh' and e.get('associated') is True and e.get('detailsOpen') is True and e.get('pageOverflow') is False,'tool-code-details association/open/overflow missing')
    companion_geometry(e.get('scroll',{}),e.get('viewport',{}),'tool-code-details scroll')
    companion_geometry(e.get('pane',{}),e.get('scroll',{}),'tool-code-details pane')
    companion_geometry(e.get('control',{}),e.get('scroll',{}),'tool-code-details control')
    literals=['echo "FINAL tool line 23 beyond excerpt"',"printf '<img src=x onerror=alert(1)> Ω'",'echo SECOND final block']
    lines=e.get('lines',[]);require([line.get('text') for line in lines]==literals,'tool-code-details visible literal identities missing')
    for line in lines:
        require(bool(line.get('rects')),'tool-code-details visible line bounds missing')
        for rect in line['rects']:companion_geometry(rect,e['pane'],'tool-code-details line')

def guard(directory,canary=False,current=False):
    directory=pathlib.Path(directory);m=json.loads((directory/'manifest.json').read_text());expected,thresholds=definitions()
    keys={(v,s) for v in (['conversation','plan'] if canary else expected) for s in SIZES}
    require(m.get('schema')==2 and m.get('container')==IMAGE and m.get('flags')==FLAGS and m.get('environment')==ENV and m.get('sizes')==SIZES,'capture runtime configuration mismatch')
    lineage=m.get('lineage',{});required=['bundleSha256','sceneSha256','captureSha256','captureFramesSha256','focusGuardSha256','horizontalGuardSha256','expectedSha256','thresholdsSha256','browserExecutableSha256','codeReadingSha256']
    require(all(sha(lineage.get(k)) for k in required),'missing source/browser lineage')
    fonts=lineage.get('fonts');require(isinstance(fonts,list) and len(fonts)==48 and len({f.get('file') for f in fonts})==48 and all(f.get('file') and sha(f.get('sha256')) for f in fonts),'font inventory invalid')
    runtime=json.loads((ROOT/'tools/chat-visual-runtime.json').read_text())
    require(m.get('browser')==runtime['browser'] and m.get('node')==runtime['node'] and lineage['fonts']==runtime['fonts'] and lineage['browserExecutableSha256']==runtime['browserExecutableSha256'],'pinned browser/node/font runtime changed')
    assets=lineage.get('mountedAssets',[]);require([x.get('file') for x in assets]==['editor.js','index.html','fabric.min.js','paper-core.min.js','svgo.browser.js'] and all(sha(x.get('sha256')) for x in assets),'mounted asset inventory incomplete')
    if current:
        for asset in assets:require(asset['sha256']==digest(ROOT/'build/editor-chat'/asset['file']),'stale mounted assets; full regeneration required')
        inputs={'bundleSha256':'build/editor-chat/editor.js','sceneSha256':'tests/scenarios/chat-activity/public-session-events.json','captureSha256':'tools/chat-visual-campaign.mjs','captureFramesSha256':'tools/chat-capture-frames.mjs','focusGuardSha256':'tools/chat-focus-guard.mjs','horizontalGuardSha256':'tools/chat-horizontal-guard.mjs','expectedSha256':'tools/chat-visual-expected.json','thresholdsSha256':'tools/chat-visual-thresholds.json','codeReadingSha256':'tests/scenarios/chat-activity/code-reading.json'}
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
        if key[0]=='focus-auto':
            focus=row.get('sidebarFocusPaint') or {}
            require(focus.get('active') is True and focus.get('outlineStyle')=='solid' and type(focus.get('outlineWidth')) in (int,float) and focus['outlineWidth']>=2 and type(focus.get('contrast')) in (int,float) and focus['contrast']>=3,'missing visible sidebar search focus ring')
            box=focus.get('box',{});viewport=focus.get('viewport',{})
            require(viewport=={'width':SIZES[key[1]]['width'],'height':SIZES[key[1]]['height']} and type(focus.get('outlineOffset')) in (int,float),'missing sidebar focus viewport')
            pad=focus['outlineWidth']+max(0,focus['outlineOffset'])
            companion_geometry(box,{'top':pad,'bottom':viewport['height']-pad,'left':pad,'right':viewport['width']-pad},'sidebar focus ring')
        if key[0] in RECOVERY_VISIBLE:recovery_guard(row)
        if key[0] in LONG_VISIBLE:long_content_guard(row)
        if key[0]=='expanded-code':expanded_code_guard(row)
        if key[0]=='tool-code-details':tool_code_details_guard(row)
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
    if not canary:
        pairs={(r['view'],r['size']):r for r in rows}
        for size in SIZES:
            require(pairs[('long-content',size)]['longContentEvidence']['cards']==pairs[('long-content-top',size)]['longContentEvidence']['cards'],'long-content paired original cards differ')
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
