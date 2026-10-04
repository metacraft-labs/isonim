#!/usr/bin/env python3
"""Campaign oracle integration controls against real capture filesystem/PNG bytes.
No browser, renderer or production DOM is mocked. Tests copy an authenticated
pinned production corpus supplied by --captures. Acceptance metadata is controlled
solely to exercise rejection and manifest binding, never claimed human approval.
"""
import argparse, hashlib, subprocess, copy, importlib.util, json, pathlib, shutil, sys, tempfile, unittest, struct, zlib
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'tools'))
from chat_visual_guard import guard, exact_canary, exact_bytes, accepted, png
p=argparse.ArgumentParser();p.add_argument('--captures',required=True);args,rest=p.parse_known_args();CAP=pathlib.Path(args.captures)
spec=importlib.util.spec_from_file_location('campaign',pathlib.Path(__file__).resolve().parents[1]/'tools/chat-visual-campaign.py');campaign=importlib.util.module_from_spec(spec);spec.loader.exec_module(campaign)
ORIGINAL_VIEWS=('empty', 'conversation', 'tools', 'plan', 'files', 'model-context', 'workspace', 'delegation', 'lifecycle', 'recovery', 'question', 'login', 'participants', 'error', 'long-content', 'completed', 'event-user_input', 'event-log', 'event-thought', 'event-tool_use', 'event-tool_result', 'event-plan', 'event-turn_complete', 'event-file_edit', 'event-file_read', 'event-diff', 'event-llm_request', 'event-context_files', 'event-context_injection', 'event-workspace', 'event-fleet_fence', 'event-fleet_host', 'event-sub_agent', 'event-delegation', 'event-orchestration', 'event-session_started', 'event-session_awaiting_input', 'event-session_resumed', 'event-session_ended', 'event-proxy_credential_rotated', 'event-proxy_rate_limit_absorbed', 'event-dispatcher_restarted', 'event-anti_halting_resume_confirmed', 'event-session_leadership_migrated', 'event-agent_question', 'event-login_required', 'event-participant', 'event-link_spans', 'event-status', 'event-error', 'tool-waiting', 'tool-running', 'thought-settled', 'event-log-bottom')
ORIGINAL_CAMPAIGN_VIEWS=('chat-draft-streaming', 'chat-first-send', 'chat-independent-first', 'chat-independent-second', 'chat-scroll-back', 'chat-scroll-latest', 'chat-selection-streaming', 'chat-send-failed', 'completed', 'conversation', 'delegation', 'empty', 'error', 'event-agent_question', 'event-anti_halting_resume_confirmed', 'event-context_files', 'event-context_injection', 'event-delegation', 'event-diff', 'event-dispatcher_restarted', 'event-error', 'event-file_edit', 'event-file_read', 'event-fleet_fence', 'event-fleet_host', 'event-link_spans', 'event-llm_request', 'event-log', 'event-log-bottom', 'event-login_required', 'event-orchestration', 'event-participant', 'event-plan', 'event-proxy_credential_rotated', 'event-proxy_rate_limit_absorbed', 'event-session_awaiting_input', 'event-session_ended', 'event-session_leadership_migrated', 'event-session_resumed', 'event-session_started', 'event-status', 'event-sub_agent', 'event-thought', 'event-tool_result', 'event-tool_use', 'event-turn_complete', 'event-user_input', 'event-workspace', 'files', 'focus-auto', 'highlight-auto', 'lifecycle', 'login', 'long-content', 'model-context', 'navigation-approved', 'navigation-auto', 'navigation-pending', 'navigation-rejected', 'navigation-stale', 'participants', 'plan', 'question', 'question-confirmation', 'question-free-form', 'question-multi-choice', 'recovery', 'selection-highlight-auto', 'thought-settled', 'tool-running', 'tool-waiting', 'tools', 'workspace')
class CaptureGuards(unittest.TestCase):
 # Read the production expected-elements authority directly, rather than the
 # captured manifest or definitions()/guard() output. Named exact keys also
 # detect duplicates, omissions and unknown rows even when counts agree.
 def expected_keys(self):
  expected=json.loads((pathlib.Path(__file__).resolve().parents[1]/'tools/chat-visual-expected.json').read_text())
  self.assertTrue(expected,'expected view inventory must be nonempty')
  original_views=set(ORIGINAL_VIEWS)
  self.assertTrue(original_views.issubset(expected),'an original required view was removed')
  for name,elements in expected.items():
   self.assertIsInstance(name,str);self.assertTrue(name.strip())
   self.assertIsInstance(elements,list);self.assertTrue(elements)
   self.assertTrue(all(isinstance(element,str) and element.strip() for element in elements))
  return sorted(name+'/'+size for name in expected for size in ('wide','narrow'))
 def assert_exact_inventory(self,rows):
  self.assertEqual(sorted(row['view']+'/'+row['size'] for row in rows),self.expected_keys())
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name);self.corpus=self.root/'corpus';shutil.copytree(CAP/'corpus',self.corpus)
 def tearDown(self):self.temp.cleanup()
 def edit(self,fn):
  path=self.corpus/'manifest.json';m=json.loads(path.read_text());fn(m);path.write_text(json.dumps(m))
 def rejected(self,fn,inventory=False):
  self.edit(fn)
  if inventory:
   with self.assertRaises(AssertionError):self.assert_exact_inventory(json.loads((self.corpus/'manifest.json').read_text())['views'])
  with self.assertRaises(ValueError):guard(self.corpus,current=True)
 def test_full_positive_and_pending_artifacts(self):
  self.assert_exact_inventory(guard(self.corpus,current=True)['views']);campaign.artifacts(self.corpus)
  self.assertIn('Empty multiline composer',(self.corpus/'review.html').read_text());self.assertEqual(json.loads((self.corpus/'perceptual-gates.json').read_text())['status'],'pending-human-baseline')
 def test_wrong_same_type_rendered_controls(self):
  # These records come from actual extra mounted pages and the same semantic
  # guard used before accepted captures, not a DTO/type-only substitution.
  for kind,literal in {'thought':'Verified the mounted preview.',
      'tool_use':'isonim inspect','session_awaiting_input':'login-provider',
      'turn_complete':'end_turn'}.items():
   for size in ('wide','narrow'):
    record=json.loads((self.corpus/f'isolated-semantic-control-{kind}-{size}.json').read_text())
    self.assertEqual(record['type'],kind);self.assertEqual(record['size'],size)
    self.assertEqual(record['wrongPayload']['type'],kind)
    self.assertTrue(record['rejected']);self.assertTrue(record['rendered'].strip())
    self.assertNotIn(literal,record['rendered'])
    self.assertEqual(record['accepted']['type'],kind)
    self.assertIn(literal,record['accepted']['text'])
    self.assertEqual(record['guard'],'isolatedContentGuard before every isolated capture')
 def test_mounted_preview_readiness_controls(self):
  for size in ('wide','narrow'):
   record=json.loads((self.corpus/f'preview-readiness-control-{size}.json').read_text())
   self.assertEqual(record['size'],size);self.assertTrue(record['absentPublishedRowsRejected']);self.assertTrue(record['wrongActualPreviewRejected'])
   self.assertEqual(record['guard'],'mountedPreviewReady used by every capture and controlReady')
   for phase in ('before','restored'):
    self.assertEqual(record[phase]['previewHeading'],'Website preview')
    self.assertTrue({'primary','secondary'}.issubset(record[phase]['sceneGraphRows']))
    self.assertTrue({'primary','secondary'}.issubset(row['id'] for row in record[phase]['state']['elements']))
 def test_readiness_missing_rows_and_wrong_preview_rejected(self):
  self.rejected(lambda m:m['views'][0]['sceneReadiness']['state'].update(elements=[]))
  shutil.copyfile(CAP/'corpus/manifest.json',self.corpus/'manifest.json')
  self.rejected(lambda m:m['views'][0]['sceneReadiness'].update(previewHeading='Wrong selected preview'))
 def test_recovery_required_pair_and_original_inventory(self):
  m=guard(self.corpus,current=True);rows={(r['view'],r['size']):r for r in m['views']}
  self.assertEqual(set(rows),{(view,size) for view in (*ORIGINAL_CAMPAIGN_VIEWS,'recovery-top','long-content-top') for size in ('wide','narrow')})
  self.assertEqual(len(rows),150)
  for size in ('wide','narrow'):
   top=rows[('recovery-top',size)];bottom=rows[('recovery',size)]
   self.assertEqual(top['events'],['proxy_credential_rotated','proxy_rate_limit_absorbed','dispatcher_restarted','anti_halting_resume_confirmed','session_leadership_migrated'])
   self.assertEqual(top['events'],bottom['events']);self.assertEqual(top['recoveryEvidence']['cards'],bottom['recoveryEvidence']['cards'])
   self.assertEqual(top['recoveryEvidence']['scrollTop'],0)
   self.assertIn(('proxy_credential_rotated','Provider access recovered'),[(v['source'],v['text']) for v in top['recoveryEvidence']['visible']])
   self.assertIn(('session_leadership_migrated','40'),[(v['source'],v['text']) for v in bottom['recoveryEvidence']['visible']])
   for view in ('recovery','recovery-top'):
    row=rows[(view,size)];self.assertEqual(hashlib.sha256((self.corpus/row['file']).read_bytes()).hexdigest(),row['sha256'])
    control=json.loads((self.corpus/f'recovery-heading-control-{view}-{size}.json').read_text())
    self.assertEqual((control['view'],control['size']),(view,size));self.assertTrue(control['missingHeadingRejected']);self.assertEqual(control['restored'],row['recoveryEvidence'])
    self.assertEqual(control['guard'],'recoveryContentGuard before both recovery captures')
 def test_recovery_missing_or_wrong_companion_metadata(self):
  for change in (lambda r:r.pop('recoveryEvidence'),lambda r:r['recoveryEvidence'].update(companion='wrong-view'),lambda r:r['recoveryEvidence'].update(position='bottom')):
   self.edit(lambda m:change(next(r for r in m['views'] if r['view']=='recovery-top')))
   with self.assertRaisesRegex(ValueError,'recovery companion metadata'):guard(self.corpus,current=True)
   shutil.copyfile(CAP/'corpus/manifest.json',self.corpus/'manifest.json')
 def test_recovery_heading_offscreen_or_missing_rejected(self):
  for change in (lambda r:r['recoveryEvidence']['visible'].pop(0),lambda r:r['recoveryEvidence']['visible'][0]['box'].update(top=-100),lambda r:r['recoveryEvidence']['cards'][0].update(text='Wrong recovery heading')):
   self.edit(lambda m:change(next(r for r in m['views'] if r['view']=='recovery-top')))
   with self.assertRaisesRegex(ValueError,'recovery'):guard(self.corpus,current=True)
   shutil.copyfile(CAP/'corpus/manifest.json',self.corpus/'manifest.json')
 def test_recovery_required_companion_capture_missing(self):
  (self.corpus/'recovery-top-narrow.png').unlink()
  with self.assertRaisesRegex(ValueError,'missing.*tampered capture PNG'):guard(self.corpus,current=True)
 def test_recovery_original_later_content_rejected(self):
  self.edit(lambda m:next(r for r in m['views'] if r['view']=='recovery')['recoveryEvidence']['cards'][-1].update(text='Missing executor migration'))
  with self.assertRaisesRegex(ValueError,'missing recovery card semantics'):guard(self.corpus,current=True)
 def test_long_content_required_pair_and_original_inventory(self):
  m=guard(self.corpus,current=True);rows={(r['view'],r['size']):r for r in m['views']}
  self.assertEqual(set(rows),{(view,size) for view in (*ORIGINAL_CAMPAIGN_VIEWS,'recovery-top','long-content-top') for size in ('wide','narrow')});self.assertEqual(len(rows),150)
  identifier='responsiveHeroWithSharedSpacingAndAccessiblePrimaryAction'*6
  for size in ('wide','narrow'):
   top=rows[('long-content-top',size)];bottom=rows[('long-content',size)]
   self.assertEqual(top['events'],['log','tool_use']);self.assertEqual(top['events'],bottom['events']);self.assertEqual(top['longContentEvidence']['cards'],bottom['longContentEvidence']['cards'])
   evidence=top['longContentEvidence'];self.assertEqual(evidence['scrollTop'],0);self.assertIn(('log','Long source identifiers remain readable: '+identifier),[(v['source'],v['text']) for v in evidence['visible']]);self.assertGreater(len(evidence['identifierLines']),1)
   self.assertIn(('log','setStyle(hero, "padding", "32px") # line 11'),[(v['source'],v['text']) for v in bottom['longContentEvidence']['visible']])
   for view in ('long-content','long-content-top'):
    row=rows[(view,size)];self.assertEqual(hashlib.sha256((self.corpus/row['file']).read_bytes()).hexdigest(),row['sha256'])
    control=json.loads((self.corpus/f'long-content-control-{view}-{size}.json').read_text());self.assertEqual((control['view'],control['size']),(view,size));self.assertEqual(control['restored'],row['longContentEvidence']);self.assertEqual(control['guard'],'longContentGuard before both long-content captures')
    self.assertEqual([c['text'] for c in control['controls']],['Assistant','Long source identifiers remain readable: '+identifier] if view=='long-content-top' else ['isonim inspect']);self.assertTrue(all(c['rejected'] for c in control['controls']))
 def test_long_content_missing_or_wrong_companion_metadata(self):
  for change in (lambda r:r.pop('longContentEvidence'),lambda r:r['longContentEvidence'].update(companion='wrong-view'),lambda r:r['longContentEvidence'].update(position='bottom')):
   self.edit(lambda m:change(next(r for r in m['views'] if r['view']=='long-content-top')))
   with self.assertRaisesRegex(ValueError,'long-content companion metadata'):guard(self.corpus,current=True)
   shutil.copyfile(CAP/'corpus/manifest.json',self.corpus/'manifest.json')
 def test_long_content_identifier_missing_offscreen_or_unwrapped_rejected(self):
  for change in (lambda e:e['visible'].pop(0),lambda e:e['identifierLines'][0].update(top=-100),lambda e:e.update(identifierLines=e['identifierLines'][:1]),lambda e:e['cards'][0].update(text='Assistant without long identifier')):
   self.edit(lambda m:change(next(r for r in m['views'] if r['view']=='long-content-top')['longContentEvidence']))
   with self.assertRaisesRegex(ValueError,'long-content'):guard(self.corpus,current=True)
   shutil.copyfile(CAP/'corpus/manifest.json',self.corpus/'manifest.json')
 def test_long_content_required_companion_capture_missing_or_tampered(self):
  png_path=self.corpus/'long-content-top-narrow.png';png_path.unlink()
  with self.assertRaisesRegex(ValueError,'missing.*tampered capture PNG'):guard(self.corpus,current=True)
  shutil.copyfile(CAP/'corpus/long-content-top-narrow.png',png_path)
  with png_path.open('ab') as f:f.write(b'changed')
  with self.assertRaisesRegex(ValueError,'missing.*tampered capture PNG'):guard(self.corpus,current=True)
 def test_long_content_original_code_tool_and_pair_corruption_rejected(self):
  for change in (lambda e:e['cards'][0].update(text=e['cards'][0]['text'].replace('# line 11','# missing')),lambda e:e['cards'][1].update(text='Tool vanished'),lambda e:e['visible'][-1]['box'].update(bottom=2000),lambda e:e['cards'][0].update(text=e['cards'][0]['text']+'extra text')):
   self.edit(lambda m:change(next(r for r in m['views'] if r['view']=='long-content')['longContentEvidence']))
   with self.assertRaisesRegex(ValueError,'long-content'):guard(self.corpus,current=True)
   shutil.copyfile(CAP/'corpus/manifest.json',self.corpus/'manifest.json')
 def test_inventory_empty(self):self.rejected(lambda m:m.update(views=[]),inventory=True)
 def test_inventory_omission(self):self.rejected(lambda m:m['views'].pop(),inventory=True)
 def test_inventory_duplicate(self):self.rejected(lambda m:m['views'].append(m['views'][0]),inventory=True)
 def test_inventory_unknown(self):self.rejected(lambda m:m['views'][0].update(view='unknown'),inventory=True)
 def test_missing_png(self):
  (self.corpus/'empty-wide.png').unlink()
  with self.assertRaises(ValueError):guard(self.corpus,current=True)
 def test_tampered_png(self):
  with (self.corpus/'empty-wide.png').open('ab') as f:f.write(b'changed')
  with self.assertRaises(ValueError):guard(self.corpus,current=True)
 def test_png_illegal_row_filter_with_valid_crc_and_length(self):
  # Controlled corruption preserves the actual PNG format, decompressed length
  # and every chunk CRC, so the production row-filter guard must reject it.
  source=(self.corpus/'empty-wide.png').read_bytes();position=8;chunks=[];idat=[]
  while position<len(source):
   length=struct.unpack('>I',source[position:position+4])[0];tag=source[position+4:position+8];data=source[position+8:position+8+length];position+=length+12
   if tag==b'IDAT':idat.append(data)
   else:chunks.append((tag,data))
  inflated=bytearray(zlib.decompress(b''.join(idat)));inflated[0]=5
  def chunk(tag,data):return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
  output=source[:8]+b''.join(chunk(tag,data) for tag,data in chunks if tag!=b'IEND')+chunk(b'IDAT',zlib.compress(inflated))+chunk(b'IEND',b'')
  bad=self.root/'invalid-filter.png';bad.write_bytes(output)
  with self.assertRaisesRegex(ValueError,'invalid PNG row filter'):png(bad)
 def test_lineage_horizontal_guard(self):self.rejected(lambda m:m['lineage'].update(horizontalGuardSha256='0'*64))
 def test_lineage_source(self):self.rejected(lambda m:m['lineage'].update(captureSha256='0'*64))
 def test_lineage_capture_frames_missing(self):
  self.edit(lambda m:m['lineage'].pop('captureFramesSha256'))
  with self.assertRaisesRegex(ValueError,'missing source/browser lineage'):guard(self.corpus,current=True)
 def test_lineage_capture_frames_stale(self):
  self.edit(lambda m:m['lineage'].update(captureFramesSha256='0'*64))
  with self.assertRaisesRegex(ValueError,'stale source closure: captureFramesSha256'):guard(self.corpus,current=True)
 def test_capture_frames_change_invalidates_review_and_preserves_findings(self):
  campaign.artifacts(self.corpus);old=json.loads((self.corpus/'findings-ledger.json').read_text());old['views']['empty/wide']['status']='reviewed';old['views']['empty/wide']['findings']=[{'id':'frame-helper-finding','priority':'P2'}];old['lineage']['captureFramesSha256']='0'*64
  campaign.artifacts(self.corpus,old);row=json.loads((self.corpus/'findings-ledger.json').read_text())['views']['empty/wide'];self.assertEqual(row['status'],'pending-independent-review');self.assertEqual(row['findings'],old['views']['empty/wide']['findings']);self.assertTrue(row['history'])
 def test_lineage_fonts(self):self.rejected(lambda m:m['lineage'].update(fonts=[]))
 def test_lineage_font_hash(self):self.rejected(lambda m:m['lineage']['fonts'][0].update(sha256='0'*64))
 def test_lineage_browser_hash(self):self.rejected(lambda m:m['lineage'].update(browserExecutableSha256='0'*64))
 def test_lineage_flags(self):self.rejected(lambda m:m.update(flags=[]))
 def test_lineage_viewport(self):self.rejected(lambda m:m['sizes']['wide'].update(width=100))
 def test_threshold(self):self.rejected(lambda m:m['views'][0]['perceptualThreshold'].update(maximumChangedPixelRatio=.99))
 def test_comparator_actual_cli_rejects_empty_inventory(self):
  self.edit(lambda m:m.update(views=[]));result=subprocess.run([sys.executable,str(campaign.repo) if hasattr(campaign,'repo') else str(pathlib.Path(__file__).resolve().parents[1]/'tools/chat-visual-compare.py'),str(self.corpus),'--report',str(self.root/'report.json')],capture_output=True)
  self.assertNotEqual(result.returncode,0);self.assertNotEqual(result.returncode,2);self.assertIn(b'empty capture inventory',result.stderr)
 def test_comparator_complete_bound_record_control(self):
  baseline=self.root/'controlled-baseline';shutil.copytree(self.corpus,baseline);m=json.loads((baseline/'manifest.json').read_text());bound=hashlib.sha256(json.dumps(m,sort_keys=True,separators=(',',':')).encode()).hexdigest()
  m['humanAcceptance']={'decision':'accepted','reviewer':'controlled metadata fixture; no actual human claim','reviewedAt':'2026-10-03T00:00:00+00:00','evidence':'test implementation header justifies this controlled approval metadata','manifestSha256':bound,'reviewedViews':sorted(v['view']+'/'+v['size'] for v in m['views']),'unresolvedP1P2':0};(baseline/'manifest.json').write_text(json.dumps(m));accepted(m)
  command=[sys.executable,str(pathlib.Path(__file__).resolve().parents[1]/'tools/chat-visual-compare.py'),str(self.corpus),'--baseline',str(baseline),'--report',str(self.root/'report.json')];result=subprocess.run(command,capture_output=True);self.assertEqual(result.returncode,0,result.stderr);self.assert_exact_inventory(json.loads((self.root/'report.json').read_text())['views'])
  self.edit(lambda candidate:candidate['views'].pop());result=subprocess.run(command,capture_output=True);self.assertNotEqual(result.returncode,0);self.assertEqual(json.loads((self.root/'report.json').read_text())['status'],'failed-capture-validation')
 def test_acceptance_boolean(self):
  m=guard(self.corpus);m['humanAcceptance']=True
  with self.assertRaises(ValueError):accepted(m)
 def test_acceptance_unbound(self):
  m=guard(self.corpus);m['humanAcceptance']={'decision':'accepted','reviewer':'controlled test peer','reviewedAt':'2026-10-03','evidence':'test-only','manifestSha256':'0'*64,'testOnly':True}
  with self.assertRaises(ValueError):accepted(m)
 def test_findings_preserved_stale_review_invalidated(self):
  campaign.artifacts(self.corpus);old=json.loads((self.corpus/'findings-ledger.json').read_text());old['views']['empty/wide']['status']='reviewed';old['views']['empty/wide']['findings']=[{'id':'actual-finding','priority':'P2'}];old['lineage']['captureSha256']='0'*64
  campaign.artifacts(self.corpus,old);new=json.loads((self.corpus/'findings-ledger.json').read_text());row=new['views']['empty/wide'];self.assertEqual(row['status'],'pending-independent-review');self.assertEqual(row['findings'],old['views']['empty/wide']['findings']);self.assertTrue(row['history'])
 def test_canary_positive_same_guard(self):self.assertEqual(len(exact_canary(CAP/'canary-a',CAP/'canary-b')['views']),4)
 def test_canary_empty_omission_duplicate_and_wrong_scope(self):
  for mutation in [lambda m:m.update(views=[]),lambda m:m['views'].pop(),lambda m:m['views'].append(m['views'][0]),lambda m:m['views'][0].update(scope='empty masked crop'),lambda m:m['views'][0].update(contentVerified=False)]:
   with self.subTest(mutation=mutation):
    target=self.root/'canary';shutil.copytree(CAP/'canary-a',target,dirs_exist_ok=True);m=json.loads((target/'manifest.json').read_text());mutation(m);(target/'manifest.json').write_text(json.dumps(m))
    with self.assertRaises(ValueError):guard(target,True,True)
    shutil.rmtree(target)
 def test_canary_mutation_control_same_guard(self):
  m=guard(CAP/'canary-a',True,True)
  for row in m['views']:
   with self.assertRaises(ValueError):exact_bytes((CAP/'canary-a'/row['file']).read_bytes(),(CAP/'canary-a'/f"{row['view']}-{row['size']}-positive-control.png").read_bytes())
 def test_canary_control_not_changed_rejected(self):
  target=self.root/'canary';shutil.copytree(CAP/'canary-a',target);m=json.loads((target/'manifest.json').read_text());row=m['views'][0];file=target/f"{row['view']}-{row['size']}-positive-control.png";shutil.copyfile(target/row['file'],file);row['positiveControl']['changedSha256']=row['sha256'];(target/'manifest.json').write_text(json.dumps(m))
  with self.assertRaises(ValueError):guard(target,True,True)
if __name__=='__main__':unittest.main(argv=[sys.argv[0],*rest])
