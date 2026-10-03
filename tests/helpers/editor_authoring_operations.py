"""Shared actual scoped CLI/compiler/catalog/mounted authoring oracles; no mocks."""
from html.parser import HTMLParser
import hashlib
import json

class CaptureMetadata(HTMLParser):
 def __init__(self):super().__init__();self.meta={};self.elements=[]
 def handle_starttag(self,tag,attributes):
  values=dict(attributes)
  if tag=='meta' and 'name' in values:self.meta[values['name']]=values.get('content')
  if values.get('data-isonim-element-id'):self.elements.append(values['data-isonim-element-id'])
def prove_operations(runtime, phase, operation_proofs, operation_responses, prior_operation_ids):
 evidence=json.loads((runtime.private/(phase+'-operations.json')).read_text())
 candidates={row['request']['commandId'] for row in evidence['operations']
             if row.get('status')=='applied' and row.get('request',{}).get('conversation')==evidence['conversation']}
 all_candidates=set(candidates)
 # Browser observations include immutable results queried again by the model.
 # Preserve those observations, but only new command identities prove this turn.
 if phase=='second-complete':candidates-=prior_operation_ids
 runtime.scope=json.loads((runtime.private/'registration.json').read_text())
 successful={}
 story='Hero pane / example '+('1' if phase=='first-complete' else '2')
 mounted=json.loads((runtime.private/(phase+'-mounted.json')).read_text())
 for command in candidates:
  try: result=runtime.cli(['wait',command,'--timeout-ms','5000'])
  except AssertionError:continue # failed/conflicting real attempts remain in wire evidence
  if result.get('status')!='applied':continue
  request=result['request']
  if request.get('conversation')!=evidence['conversation']:raise AssertionError('Operation belongs to a different conversation')
  matching=[row for row in evidence['operations'] if row.get('request')==request and row.get('status')=='applied']
  if not matching:raise AssertionError('CLI result lacks an exact applied browser acknowledgement')
  if any(request.get(key)!=runtime.scope[key] for key in ('workspace','instance','epoch')):raise AssertionError('Real tool targeted a different mounted editor')
  operation=request.get('command')
  if operation not in ('create-story','build','open-story','capture-preview'):continue
  private_result=runtime.private/(phase+'-'+command+'.json')
  private_result.write_text(json.dumps(result));private_result.chmod(0o600)
  if operation=='create-story':
   if (result['result'].get('ok') is not True or result['result'].get('storyId')!=story or
       request.get('component')!='Hero pane' or request.get('variantKey')!='example' or
       request.get('stateKey')!=('1' if phase=='first-complete' else '2')):
    raise AssertionError('Fresh create-story does not target the intended durable fixture')
  if operation=='build' and result['result'].get('ok') is not True:
   raise AssertionError('Fresh actual build did not compile successfully')
  if operation=='open-story' and request.get('storyId')!=story:
   raise AssertionError('Fresh navigation did not target the intended mounted story')
  if operation=='capture-preview':
   capture=result['result'];html=capture.get('documentHtml','')
   document=CaptureMetadata();document.feed(html)
   if (capture.get('format')!='text/html' or capture.get('storyId')!=story or len(html)<100 or
       capture.get('previewGeneration')!=mounted['generation'] or mounted['story']!=story or
       document.meta.get('isonim-rendered-story')!=story or
       document.meta.get('isonim-rendered-generation')!=str(mounted['generation']) or
       sorted(document.elements)!=mounted['elements']):raise AssertionError('Real agent capture does not match the exact mounted story/generation/element tree')
   successful[operation]={'operationId':command,'revision':result['revision'],'story':capture['storyId'],'generation':capture['previewGeneration'],'htmlBytes':len(html),'htmlSha256':hashlib.sha256(html.encode()).hexdigest()}
  else:successful[operation]={'operationId':command,'revision':result['revision']}
  operation_responses[1 if phase=='first-complete' else 2][command]=result
 if set(successful)!={'create-story','build','open-story','capture-preview'}:raise AssertionError('Each actual turn must complete applied create/build/open/capture: '+str(sorted(successful)))
 catalog=(runtime.project/'.isonim/catalog.json').read_text()
 if story not in {row['group']+' / '+row['name'] for row in json.loads(catalog)['stories']}:raise AssertionError('Actual story is absent from durable compiler catalog')
 if (runtime.project/runtime.source_file).read_text()==runtime.before:raise AssertionError('Actual story creation produced no durable source mutation')
 source_hash=hashlib.sha256((runtime.project/runtime.source_file).read_bytes()).hexdigest()
 if phase=='second-complete' and source_hash==operation_proofs['first-complete']['sourceSha256']:raise AssertionError('Follow-up produced no second durable source mutation')
 prior_operation_ids.update(all_candidates)
 operation_proofs[phase]={'operations':successful,'sourceSha256':source_hash,'catalogSha256':hashlib.sha256(catalog.encode()).hexdigest()}
