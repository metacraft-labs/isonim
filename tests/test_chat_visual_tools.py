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
 def test_lineage_source(self):self.rejected(lambda m:m['lineage'].update(captureSha256='0'*64))
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
