#!/usr/bin/env python3
"""Real compiler/renderer/SSR checks for explicit public metadata, not privacy.

No mocks: use NativeRenderer, WebRenderer in Chromium, and shipped SSR writers.
Each invalid authored element has an independently compiled legal counterpart.
"""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
UI=Path('src/isonim/dsl/ui.nim')
def artifact(p):
 s=p.stat();return dict(sha256=hashlib.sha256(p.read_bytes()).hexdigest(),size=s.st_size,mode=s.st_mode,mtime_ns=s.st_mtime_ns)
def save(p,v):p.write_text(json.dumps(v,sort_keys=True,indent=2)+'\n')
CASES=[
 ('uppercase-false','input(PUBLIC = false)','input(PUBLIC = true)','requires public = true'),
 ('quoted-false','input(`public` = false)','input(`public` = true)','requires public = true'),
 ('uppercase-forged','input(PUBLIC = true, `DATA-ISONIM-PUBLIC` = "true")','input(PUBLIC = true)','use public = true or sensitive = true'),
 ('quoted-forged','input(`public` = true, `data-isonim-sensitive` = "true")','input(`public` = true)','use public = true or sensitive = true'),
 ('false','input(public = false)','input(public = true)','requires public = true'),
 ('nonliteral','input(public = dynamicChoice)','input(public = true)','requires literal'),
 ('duplicate','input(public = true, public = true)','input(public = true)','duplicate input privacy attribute'),
 ('duplicate-type','input(public = true, `type` = "text", TYPE = "text")','input(public = true, `type` = "text")','duplicate input privacy attribute'),
 ('both','input(public = true, sensitive = true)','input(public = true)','choose exactly one'),
 ('both-false','input(public = true, sensitive = false)','input(public = true)','choose exactly one'),
 *[(f'password{i}',f'input(public = true, `type` = "{v}")','input(public = true, `type` = "text")','credential input must be sensitive') for i,v in enumerate(['password','PaSsWoRd'])],
 *[(f'credential{i}',f'input(public = true, autocomplete = {json.dumps(v)})','input(public = true, autocomplete = "off")','credential input must be sensitive') for i,v in enumerate(['cc-number','section-shipping CC-name','current-password','NEW-PASSWORD','one-time-code','name\tone-time-code','cc-name\femail','\rcc-exp\n'])],
 *[(f'marker{i}',f'input(public = true, `{v}` = "true")','input(public = true)','use public = true or sensitive = true') for i,v in enumerate(['data-isonim-public','data-isonim-sensitive'])],
 *[(f'record{i}',f'input(public = true, record = {v})','input(public = true)','record is retired; choose public = true or sensitive = true') for i,v in enumerate(['true','false'])],
 ('record-marker','input(public = true, `data-isonim-record` = "true")','input(public = true)','record is retired; choose public = true or sensitive = true'),
 ('unsupported-type','input(public = true, `type` = "")','input(public = true, `type` = "text")','unsupported private input type'),
 ('unsupported-editable','tdiv(public = true, contenteditable = "inherit")','tdiv(public = true, contenteditable = "false")','unsupported private contenteditable state'),
]
HEADER='''import isonim/rxcore
import isonim/renderers/native
import isonim/dsl/ui
import isonim/ssr/[escape, stream]
let r = NativeRenderer()
let dynamicChoice = true
'''
def source(mode,element):
 return HEADER+{'client':'discard ui(r):\n','string':'discard ui:\n','stream':'let output = newStringOutputStream()\nuiWrite(output):\n'}[mode]+'  '+element+'\n'
def expression_source(mode,attribute,expression,refuse):
 # Use the same permanent assertion in the baseline and admission inverse.
 # These are real renderer/writer fixtures, never compile-error privacy tests.
 element='input(public = true, `'+attribute+'` = '+expression+')'
 if mode=='client':
  operation='let target = ui(r):\n  '+element
  legal='doAssert target.attributes["'+attribute+'"] == expected, "public expression client exact bytes"'
 elif mode=='string':
  operation='let html = ui:\n  '+element
  legal='doAssert html == "<input data-isonim-public=\\\"true\\\" '+attribute+'=\\\"" & expected & "\\\" />", "public expression string exact bytes"'
 else:
  operation='uiWrite(output):\n  '+element
  legal='doAssert output.getOutput() == "<input data-isonim-public=\\\"true\\\" '+attribute+'=\\\"" & expected & "\\\" />", "public expression stream exact bytes"'
 imports=HEADER+'import std/tables\n'
 expected='text' if attribute=='type' else 'off'
 body='let expected = "'+expected+'"\n'
 if refuse:
  body+='var refused = false\ntry:\n'+''.join('  '+line+'\n' for line in operation.splitlines())
  body+='except ValueError as e: refused = e.msg == "credential input cannot be public"\n'
  body+='doAssert refused, "public '+mode+' dollar-literal '+attribute+' privacy guard"\n'
  if mode=='stream':
   body+='doAssert output.getOutput() == "<input data-isonim-public=\\\"true\\\" '+attribute+'=\\\"", "public expression refusal preserves prefix"\n'
   body+='uiWrite(output):\n  input(public = true, autocomplete = $"off")\n'
   body+='doAssert output.getOutput().endsWith("<input data-isonim-public=\\\"true\\\" autocomplete=\\\"off\\\" />"), "public expression legal stream write after refusal"\n'
 else:body+=operation+'\n'+legal+'\n'
 if mode=='stream':
  imports+='import std/strutils\nvar outputs = @[newStringOutputStream()]\nvar callbackBytes = ""\noutputs.add(newCallbackOutputStream(proc(s: string) = callbackBytes.add(s)))\nwhen defined(useFaststreams): outputs.add(newFastOutputStream())\nfor output in outputs:\n'
  body=''.join('  '+line+'\n' for line in body.splitlines())
 return imports+body
def prepare(d):
 d.mkdir(parents=True,exist_ok=False);rows=[]
 for mode in ['client','string','stream']:
  for name,invalid,legal,diagnostic in CASES:
   row=dict(mode=mode,name=name,diagnostic=diagnostic)
   for arm,element in [('invalid',invalid),('legal',legal)]:
    p=d/(mode+'_'+name.replace('-','_')+'_'+arm+'.nim');p.write_text(source(mode,element));row[arm]=str(p);row[arm+'_line']=len(p.read_text().splitlines())
   rows.append(row)
 # Public named helper parameters do not acquire element policy; existing raw
 # record behavior remains explicitly outside this bounded public branch.
 for mode in ['client','string','stream']:
  for name,element in [('textarea-type','textarea(public = true, `type` = "password")'),('div-type','tdiv(public = true, `type` = "password")'),('ttype-attribute','input(public = true, ttype = "password")'),('lookalike','input(public = true, autocomplete = "x-current-password")'),('vtab','input(public = true, autocomplete = "x\\vcc-number")'),('nbsp','input(public = true, autocomplete = "x\\u00a0cc-number")'),('nonfield','button(public = true)'),('legacy','input(`type` = "text", value = "legacy")'),('legacy-record','input(record = false)')]:
   p=d/(mode+'_'+name.replace('-','_')+'.nim');p.write_text(source(mode,element))
 helper=d/'helper.nim';helper.write_text(HEADER+'proc component[R](r: R; public: bool): auto =\n  doAssert public\n  r.createElement("span")\ndiscard ui(r):\n  component[NativeRenderer](r, public = true)\n')
 original=(ROOT/UI).read_text()
 mutations={}
 editor_old='checkedPrivacyValue(privacy, htmlTag, property,\n                    newCall(bindSym"val", cellSym))'
 assert original.count(editor_old)==1
 mutations['editor-cell']=original.replace(editor_old,'newCall(bindSym"val", cellSym)')
 expressions=[]
 for mode in ['client','string','stream']:
  for attribute,bad,good in [('type','password','text'),('autocomplete','cc-number','off')]:
   for depth in [1,2]:
    for arm,value in [('refusal',bad),('legal',good)]:
     expression='$'+json.dumps(value) if depth==1 else '$($'+json.dumps(value)+')'
     p=d/('expression_'+mode+'_'+attribute+'_'+str(depth)+'_'+arm+'.nim')
     p.write_text(expression_source(mode,attribute,expression,arm=='refusal'))
     expressions.append(dict(mode=mode,attribute=attribute,depth=depth,arm=arm,path=str(p)))
 # Restore the old admission decision in the actual client generator only.
 # Its dollar-literal fixture must compile and fail the same refusal assertion;
 # restoring streaming's old decision would instead fail macro compilation.
 old='let attrVal = if authoredVal.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:'
 assert original.count(old)==3
 mutations['admission-client']=original.replace(old,'let attrVal = if isDynamic(authoredVal):',1)
 marker_paths={
  'client':('newLit("data-isonim-public"), newLit("true")','newLit("data-isonim-public-disabled"), newLit("true")'),
  'string':('tagParts.add(newLit(" data-isonim-public=\\\"true\\\""))','tagParts.add(newLit(" data-isonim-public-disabled=\\\"true\\\""))'),
  'stream':('openTag.add(" data-isonim-public=\\\"true\\\"")','openTag.add(" data-isonim-public-disabled=\\\"true\\\"")'),
 }
 for mode,(old,new) in marker_paths.items():
  assert original.count(old)==1,(mode,old)
  mutations['marker-'+mode]=original.replace(old,new)
 old='checkedPrivacyValue(privacy, htmlTag, attrName, authoredVal)'
 assert original.count(old)==3
 for attribute in ['type','autocomplete']:
  new='(if attrName.toLowerAscii == "'+attribute+'": authoredVal else: '+old+')'
  for index,mode in enumerate(['client','string','stream']):
   parts=original.split(old)
   mutated=old.join(parts[:index+1])+new+old.join(parts[index+1:])
   mutations[attribute+'-'+mode]=mutated
 for name,mutated in mutations.items():
  root=d/'mutants'/name;shutil.copytree(ROOT/'src',root/'src',symlinks=True)
  (root/UI).write_text(mutated)
 save(d/'CASES.json',rows)
 save(d/'EXPRESSIONS.json',expressions)
 save(d/'GENERATED-BEFORE.json',{str(p):artifact(p) for p in sorted(d.rglob('*')) if p.is_file() and not p.is_symlink()})
def run(d,nim,node,browser=False):
 commands=[]
 def command(label,args,expected=0,diagnostic=None,location=None):
  r=subprocess.run(args,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  log=d/(label+'.log');log.write_text(r.stdout);commands.append(dict(label=label,argv=args,exit=r.returncode,log=artifact(log)));save(d/'COMMANDS.json',commands)
  assert (r.returncode==0 if expected==0 else r.returncode!=0),(label,r.stdout)
  if diagnostic:assert diagnostic in r.stdout,(label,r.stdout)
  if location:assert location in r.stdout,(label,r.stdout)
  print(label,r.returncode,flush=True)
 def flags(target,label,extra=[]):
  return [nim,target,'--verbosity:2','--listFullPaths:on','--path:'+str(ROOT/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--path:'+str(ROOT.parent/'nim-faststreams'),'--path:'+str(ROOT.parent/'nim-stew'),'--nimcache:'+str(d/'cache'/label),'-d:tailwindStylesPathOverride='+str(ROOT/'tests/dsl/tailwind/variant-styles.json'),*extra]
 # Native optional backend is required, never skipped or sent to JS.
 label='native-faststreams';out=d/(label+'.bin');command(label+'-compile',[*flags('c',label,['-d:useFaststreams']),'--out:'+str(out),str(ROOT/'tests/test_public_directive.nim')]);before=artifact(out);save(d/(label+'-EMITTED-BEFORE.json'),before);command(label+'-execute',[str(out)]);assert artifact(out)==before
 # Compile unchanged ordinary WebRenderer fixture, then execute the complete
 # shared assertions against shipped WebRenderer and real Chromium DOM.
 label='web-original-fixture';out=d/(label+'.js');command(label,[*flags('js',label),'--out:'+str(out),str(ROOT/'tests/test_public_directive_web.nim')])
 label='web-runtime';out=d/(label+'.js');command(label+'-compile',[*flags('js',label,['-d:isonimPublicBrowser']),'--out:'+str(out),str(ROOT/'tests/test_public_directive.nim')]);before=artifact(out);save(d/(label+'-EMITTED-BEFORE.json'),before)
 command(label+'-browser',[node,str(ROOT/'tests/test_public_directive_browser.mjs'),str(out),str(d/'BROWSER-RESULT.json')]);assert artifact(out)==before
 for target in ['c','js']:
  for variant in ['original',*[kind+'-'+mode for kind in ['marker','type','autocomplete'] for mode in ['client','string','stream']]]:
   label=target+'-runtime-'+variant;out=d/(label+('.js' if target=='js' else '.bin'))
   extra=[] if variant=='original' else ['--path:'+str(d/'mutants'/variant/'src')]
   command(label+'-compile',[*flags(target,label,extra),'--out:'+str(out),str(ROOT/'tests/test_public_directive.nim')])
   before=artifact(out);save(d/(label+'-EMITTED-BEFORE.json'),before)
   marker=None
   location=None
   if variant!='original':
    kind,mode=variant.split('-')
    if kind=='marker':marker={'client':'public client marker is required','string':'public string SSR marker and directive consumption','stream':'public stream marker and directive consumption'}[mode]
    elif mode=='client':marker='public UI '+kind+' must refuse credential before renderer assignment'
    else:marker={'string':'public string SSR rejects credentials','stream':'public stream rejects credentials before escaped writer'}[mode]
    source=ROOT/'tests/test_public_directive.nim'
    hits=[index+1 for index,line in enumerate(source.read_text().splitlines()) if 'doAssert' in line and '"'+marker+'"' in line]
    assert len(hits)==1,(variant,hits)
    location=f'{source}({hits[0]},'

   command(label+'-execute',[node,str(out)] if target=='js' else [str(out)],expected=int(variant!='original'),diagnostic=marker,location=location)
   if variant!='original':assert '[AssertionDefect]' in (d/(label+'-execute.log')).read_text()
   assert artifact(out)==before
  for row in json.loads((d/'CASES.json').read_text()):
   for arm in ['invalid','legal']:
    label=target+'-'+row['mode']+'-'+row['name']+'-'+arm;p=Path(row[arm])
    command(label,[*flags(target,label),'--compileOnly','--out:'+str(d/(label+'.out')),str(p)],expected=int(arm=='invalid'),diagnostic=row['diagnostic'] if arm=='invalid' else None,location=f'{p}({row[arm+"_line"]},' if arm=='invalid' else None)
  paired={row[arm] for row in json.loads((d/'CASES.json').read_text()) for arm in ['invalid','legal']}
  expressions=json.loads((d/'EXPRESSIONS.json').read_text())
  for row in expressions:
   for fast in ([False,True] if target=='c' and row['mode']=='stream' else [False]):
    p=Path(row['path']);label=target+'-'+p.stem+('-faststreams' if fast else '');out=d/(label+('.js' if target=='js' else '.bin'))
    command(label+'-compile',[*flags(target,label,['-d:useFaststreams'] if fast else []),'--out:'+str(out),str(p)])
    before=artifact(out);save(d/(label+'-EMITTED-BEFORE.json'),before)
    command(label+'-execute',[node,str(out)] if target=='js' else [str(out)])
    assert artifact(out)==before
  row=next(row for row in expressions if row['mode']=='client' and row['attribute']=='type' and row['depth']==1 and row['arm']=='refusal')
  p=Path(row['path']);label=target+'-admission-client';out=d/(label+('.js' if target=='js' else '.bin'))
  command(label+'-compile',[*flags(target,label,['--path:'+str(d/'mutants/admission-client/src')]),'--out:'+str(out),str(p)])
  before=artifact(out);save(d/(label+'-EMITTED-BEFORE.json'),before)
  marker='public client dollar-literal type privacy guard'
  hits=[index+1 for index,line in enumerate(p.read_text().splitlines()) if 'doAssert' in line and '"'+marker+'"' in line];assert len(hits)==1
  command(label+'-execute',[node,str(out)] if target=='js' else [str(out)],expected=1,diagnostic=marker,location=f'{p}({hits[0]},')
  assert '[AssertionDefect]' in (d/(label+'-execute.log')).read_text()
  assert artifact(out)==before
  paired.update(row['path'] for row in expressions)
  for p in sorted(d.glob('*.nim')):
   if str(p) in paired:continue
   label=target+'-control-'+p.stem;command(label,[*flags(target,label),'--compileOnly','--out:'+str(d/(label+'.out')),str(p)])
 # The editor flag is the actual production regime being qualified, not a
 # test override. Every inverse compiles and reaches the original assertion.
 for target in ['c','js']:
  for variant in ['original','editor-cell']:
   label=target+'-editor-'+variant;out=d/(label+('.js' if target=='js' else '.bin'))
   extra=['-d:isonimEditor']+([] if variant=='original' else ['--path:'+str(d/'mutants/editor-cell/src')])
   source=ROOT/'tests/test_public_directive_editor.nim'
   command(label+'-compile',[*flags(target,label,extra),'--out:'+str(out),str(source)])
   before=artifact(out);save(d/(label+'-EMITTED-BEFORE.json'),before)
   marker='public editor cell credential guard' if variant!='original' else None
   hits=[index+1 for index,line in enumerate(source.read_text().splitlines()) if 'doAssert' in line and '"'+str(marker)+'"' in line]
   command(label+'-execute',[node,str(out)] if target=='js' else [str(out)],expected=int(variant!='original'),diagnostic=marker,location=f'{source}({hits[0]},' if marker else None)
   if marker:assert '[AssertionDefect]' in (d/(label+'-execute.log')).read_text()
   assert artifact(out)==before
 label='web-editor';out=d/(label+'.js')
 command(label+'-compile',[*flags('js',label,['-d:isonimEditor','-d:isonimPublicBrowser']),'--out:'+str(out),str(ROOT/'tests/test_public_directive_editor.nim')])
 before=artifact(out);save(d/(label+'-EMITTED-BEFORE.json'),before)
 command(label+'-browser',[node,str(ROOT/'tests/test_public_directive_browser.mjs'),str(out),str(d/'EDITOR-BROWSER-RESULT.json')]);assert artifact(out)==before
 for p,w in json.loads((d/'GENERATED-BEFORE.json').read_text()).items():assert artifact(Path(p))==w,p
 save(d/'RESULT.json',dict(status='PASS',scope='explicit public metadata only',commands=len(commands),cases=len(CASES),commands_sha256=artifact(d/'COMMANDS.json')['sha256']))
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prepare',type=Path);p.add_argument('--run',type=Path);p.add_argument('--nim',default=shutil.which('nim'));p.add_argument('--node',default=shutil.which('node'));a=p.parse_args()
 if a.prepare:prepare(a.prepare)
 elif a.run:run(a.run,a.nim,a.node)
 else:
  with tempfile.TemporaryDirectory(prefix='isonim-public-') as name:
   d=Path(name)/'fixtures';prepare(d);run(d,a.nim,a.node)
if __name__=='__main__':main()
