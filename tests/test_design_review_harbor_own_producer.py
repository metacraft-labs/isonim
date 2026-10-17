"""Real Git/Repro/Just/cache admission controls for the own-producer interface.

No filesystem, process, digest, Repro or compiler APIs are mocked. A tiny public
Just producer copies an authored executable instead of compiling private Rust:
this lets tests change source and publish bad cache outputs without touching
Harbor or invoking a model. The actual latest Harbor build and REST scenario
are separate owning integration gates. Git commits below belong only to fresh,
throwaway fixture repositories, never the developer's source checkout.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'tools/isonim_review/harbor_producer.py'
spec = importlib.util.spec_from_file_location('producer', HELPER)
producer = importlib.util.module_from_spec(spec); spec.loader.exec_module(producer)


class OwnProducer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Keep the genuine compiler interface path stable; each case gets a new
        # actual Git/source fixture and cache output. No outcomes are reused.
        cls.temp = tempfile.TemporaryDirectory(prefix='isonim-own-producer-')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.root = Path(self.temp.name)
        self.repo = self.root / 'agent-harbor'; self.repo.mkdir(exist_ok=True)
        for path in self.repo.iterdir():
            if path.name == '.repro': continue
            if path.is_dir() and not path.is_symlink(): shutil.rmtree(path)
            else: path.unlink()
        self.cache = self.root / 'producer-cache'; self.cache.mkdir(exist_ok=True)
        self.output = self.cache / 'debug/ah'
        self.publication = self.root / 'consumer/harbor-executable'
        self.publication.parent.mkdir(exist_ok=True)
        self.publication.unlink(missing_ok=True)
        (self.publication.parent/'producer-interface.json').unlink(missing_ok=True)
        (self.repo / '.gitignore').write_text('.repro/\n')
        (self.repo / 'repro.nim').write_text('''import repro_project_dsl
import repro_dsl_stdlib/packages/sh
import repro_dsl_stdlib/packages/python3
package fixture:
  defaultToolProvisioning "path"
  uses:
    "sh"
    "python3"
  devEnv:
    setEnv("ISONIM_OWN_PRODUCER_FIXTURE", "activated")
''')
        (self.repo / 'dev-bin').mkdir()
        (self.repo / 'dev-bin/just').write_text('#!/bin/sh\nexec '+shutil.which('just')+' "$@"\n')
        (self.repo / 'dev-bin/just').chmod(0o700)
        (self.repo / 'Justfile').write_text('target_dir := '+json.dumps(str(self.cache))+'''
build-rust-unit-test-binaries:
    python3 build.py
''')
        (self.repo / 'build.py').write_text('''import os,pathlib,shutil,time
assert os.environ['ISONIM_OWN_PRODUCER_FIXTURE']=='activated'
root=pathlib.Path.cwd(); target=pathlib.Path('''+repr(str(self.output))+(
  ')\n'
  'target.parent.mkdir(exist_ok=True)\n'
  "if (root/'block-build').exists():\n"
  " target.with_name('blocked-pid').write_text(str(os.getpid()))\n"
  " root.joinpath('build-started').touch();time.sleep(60)\n"
  "if (root/'fail').exists():raise SystemExit(42)\n"
  "if (root/'change-during-build').exists():root.joinpath('main.sh').write_text('#!/bin/sh\\nprintf CHANGED\\n')\n"
  "if (root/'escape-output').exists():\n"
  " target.unlink(missing_ok=True);target.symlink_to(root/'build/bin/ah')\n"
  'else:\n'
  " target.unlink(missing_ok=True);shutil.copyfile(root/'main.sh',target);target.chmod(0o700)\n"
  " if (root/'src/ignored.inc').exists():\n"
  "  with target.open('ab') as output:output.write(b'\\n# ignored input: '+(root/'src/ignored.inc').read_bytes()+b'\\n')\n"
  " if (root/'assets/input.inc').exists():\n"
  "  with target.open('ab') as output:output.write(b'\\n# authored asset: '+(root/'assets/input.inc').read_bytes()+b'\\n')\n"
  "  if (root/'change-asset-during-build').exists():root.joinpath('assets/input.inc').write_text('mutated during build')\n"
  " if (root/'assets/node_modules/input.inc').exists():\n"
  "  with target.open('ab') as output:output.write(b'\\n# authored directory: '+(root/'assets/node_modules/input.inc').read_bytes()+b'\\n')\n"
))
        (self.repo / 'main.sh').write_text('#!/bin/sh\nprintf CURRENT_SOURCE\n')
        (self.repo / 'build/bin').mkdir(parents=True)
        (self.repo / 'build/bin/ah').write_text('#!/bin/sh\nprintf STALE_LEGACY\n')
        (self.repo / 'build/bin/ah').chmod(0o700)
        subprocess.run(['git','init','-q'],cwd=self.repo,check=True)
        subprocess.run(['git','add','.'],cwd=self.repo,check=True)
        subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                        'commit','-qm','fixture'],cwd=self.repo,check=True)

    def build(self):
        if self._testMethodName=='test_real_producer_activation_external_cache_stage_reuse_and_local_edit':
            self.run_driver()
        else:
            producer.build(self.repo,self.publication)
        return Path(self.publication.read_text().strip())

    def run_driver(self, check=True):
        driver=os.environ.get('ISONIM_HARBOR_BUILD_DRIVER',
                              str(ROOT/'build/test-bin/test_design_review_harbor_build'))
        return subprocess.run([driver,'--own-producer-build',str(self.repo),
                                str(self.publication.parent)],check=check,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)

    def test_generated_policy_matches_normalized_posix_and_windows_paths(self):
        from pathlib import PurePosixPath, PureWindowsPath
        import cProfile
        candidates=['target/file','target-prefix/file','./target//file',
                    'target/../authored','../target/file','/target/file',
                    '.repro/build/file','.repro/build-prefix/file',
                    'docs/.repro/build/file','TARGET/file','C:/target/file',
                    r'target\file','ah-lib/dist/file','ah-lib/distribution/file']
        for path_type in [PurePosixPath,PureWindowsPath]:
            for name in candidates:
                path=path_type(name)
                expected=any(path.is_relative_to(path_type(root.as_posix()))
                              for root in producer.GENERATED_ROOTS)
                self.assertEqual(producer.generated_location(path),expected,(path_type,name))
        # The regression is repeated construction of every lexical ancestor,
        # not wall-clock noise. Profile the real classifier over actual ignored
        # files and require zero is_relative_to calls; no OS/API is substituted.
        directory=self.repo/'.repro/build/deep/inputs'
        directory.mkdir(parents=True)
        for index in range(128):(directory/str(index)).write_text('producer output')
        ignored=[os.fsdecode(name) for name in producer.git(self.repo,'ls-files',
                  '--others','--ignored','--exclude-standard','-z').split(b'\0') if name]
        profile=cProfile.Profile();profile.enable()
        classifications=[producer.generated_input(self.repo,name) for name in ignored]
        profile.disable()
        self.assertTrue(all(classifications))
        self.assertEqual(sum(entry.callcount for entry in profile.getstats()
            if hasattr(entry.code,'co_name') and entry.code.co_name=='is_relative_to'),0)

    def test_snapshot_retains_tracked_generated_and_ignored_lookalike_gitlink_sources(self):
        # Real Git/gitlink/filesystem controls, including inputs below generated
        # names. Tracked inputs override classification; ignored authored assets
        # outside precisely identified output roots remain source inputs.
        tracked=self.repo/'target/tracked.inc';tracked.parent.mkdir(exist_ok=True)
        tracked.write_text('tracked beneath generated root')
        (self.repo/'.gitignore').write_text('.repro/\ntarget/\nassets/\ndocs/\n')
        subprocess.run(['git','add','-f','target/tracked.inc','.gitignore'],cwd=self.repo,check=True)
        authored=self.repo/'assets/target-prefix/input.inc';authored.parent.mkdir(parents=True)
        authored.write_text('ignored authored lookalike')
        nested=self.repo/'docs/.repro/build/input.inc';nested.parent.mkdir(parents=True)
        nested.write_text('authored nested policy lookalike')
        generated=self.repo/'target/generated.inc';generated.write_text('generated output')
        source=self.root/'nested-source';source.mkdir(exist_ok=True)
        subprocess.run(['git','init','-q'],cwd=source,check=True)
        (source/'.gitignore').write_text('assets/\n')
        (source/'input.inc').write_text('real gitlink source')
        subprocess.run(['git','add','.'],cwd=source,check=True)
        subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                        'commit','--allow-empty','-qm','gitlink fixture'],cwd=source,check=True)
        subprocess.run(['git','-c','protocol.file.allow=always','submodule','add','-q',str(source),'nested'],cwd=self.repo,check=True)
        ignored=self.repo/'nested/assets/node_modules/input.inc';ignored.parent.mkdir(parents=True)
        ignored.write_text('gitlink ignored authored asset without package owner')
        first=producer.snapshot(self.repo)
        for name in ['target/tracked.inc','assets/target-prefix/input.inc',
                      'docs/.repro/build/input.inc','nested/input.inc',
                      'nested/assets/node_modules/input.inc']:
            self.assertIn(name,first['files'])
        self.assertNotIn('target/generated.inc',first['files'])
        self.assertIn('nested/',first['revisions'])
        self.assertEqual(producer.snapshot(self.repo,first),first)
        previous=ignored.stat();ignored.write_text('changed gitlink ignored authored asset')
        os.utime(ignored,ns=(previous.st_atime_ns,previous.st_mtime_ns))
        changed=producer.snapshot(self.repo,first)
        self.assertNotEqual(changed['sha256'],first['sha256'])
        self.assertNotEqual(changed['files']['nested/assets/node_modules/input.inc']['sha256'],
                            first['files']['nested/assets/node_modules/input.inc']['sha256'])

    def test_real_entry_refuses_insecure_stage_and_selected_build_failure(self):
        stage=self.repo/producer.STAGE
        stage.mkdir(parents=True,exist_ok=True);stage.chmod(0o755)
        rejected=self.run_driver(check=False)
        self.assertNotEqual(rejected.returncode,0,rejected.stdout)
        self.assertIn('Invalid private Harbor stage',rejected.stderr)
        self.assertEqual(stage.stat().st_mode&0o777,0o755)
        self.assertFalse(self.publication.exists())
        stage.chmod(0o700);(self.repo/'fail').touch()
        rejected=self.run_driver(check=False)
        self.assertNotEqual(rejected.returncode,0,rejected.stdout)
        self.assertIn('refusing an installed fallback',rejected.stderr)
        self.assertFalse(self.publication.exists())

    def test_cache_name_without_owning_package_is_authored_input(self):
        directory=self.repo/'assets/node_modules';directory.mkdir(parents=True)
        (self.repo/'.gitignore').write_text('.repro/\nassets/node_modules/\n')
        asset=directory/'input.inc';asset.write_text('authored before')
        binary=self.build()
        self.assertIn(b'authored before',binary.read_bytes())
        asset.write_text('authored after')
        with self.assertRaisesRegex(RuntimeError,'source changed'):
            producer.verify(self.repo,binary)
        current=self.build()
        self.assertIn(b'authored after',current.read_bytes())
        self.assertNotEqual(producer.digest(binary),producer.digest(current))

    def test_source_changed_during_actual_own_query_is_rejected(self):
        launcher=self.repo/'dev-bin/just'
        launcher.write_text('#!/bin/sh\nprintf QUERY_EDIT >> main.sh\nexec '+
                            shutil.which('just')+' "$@"\n')
        selection=self.publication.parent/'producer-interface.json'
        with self.assertRaisesRegex(RuntimeError,'source changed during producer query'):
            producer.select(self.repo,selection)
        self.assertFalse(selection.exists())

    def test_real_entry_cancels_selected_own_producer_without_publication(self):
        (self.repo/'block-build').touch()
        driver=os.environ.get('ISONIM_HARBOR_BUILD_DRIVER',
                              str(ROOT/'build/test-bin/test_design_review_harbor_build'))
        result=subprocess.run([driver,'--own-producer-build-cancel',str(self.repo),
                                str(self.publication.parent),str(self.repo/'build-started')],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=90)
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertIn('build interrupted',result.stderr)
        self.assertFalse(self.publication.exists())
        blocked=int(self.output.with_name('blocked-pid').read_text())
        with self.assertRaises(ProcessLookupError):os.kill(blocked,0)

    def test_real_producer_activation_external_cache_stage_reuse_and_local_edit(self):
        binary=self.build(); receipt=json.loads((binary.parent/'receipt.json').read_text())
        self.assertTrue(binary.is_relative_to(self.repo.resolve()/producer.STAGE))
        self.assertEqual(receipt['producerArtifact'],str(self.output))
        self.assertEqual(producer.digest(binary),producer.digest(self.output))
        self.assertEqual(subprocess.check_output([binary],text=True),'CURRENT_SOURCE')
        self.assertEqual(binary.stat().st_mode&0o777,0o700)
        self.assertEqual((binary.parent/'receipt.json').stat().st_mode&0o777,0o600)
        self.assertEqual(self.build(),binary)
        (self.repo/'main.sh').write_text('#!/bin/sh\nprintf LOCAL_EDIT\n')
        with self.assertRaisesRegex(RuntimeError,'source changed'):producer.verify(self.repo,binary)
        current=self.build()
        self.assertNotEqual(current,binary)
        self.assertEqual(subprocess.check_output([current],text=True),'LOCAL_EDIT')

    def test_source_changed_during_build_cannot_publish(self):
        (self.repo/'change-during-build').touch()
        with self.assertRaisesRegex(RuntimeError,'source changed during'):self.build()
        self.assertFalse(self.publication.exists())

    def test_failed_producer_and_escaping_output_refuse_stale_legacy(self):
        (self.repo/'fail').touch()
        with self.assertRaises(subprocess.CalledProcessError):self.build()
        self.assertFalse(self.publication.exists())
        (self.repo/'fail').unlink();(self.repo/'escape-output').touch()
        with self.assertRaisesRegex(RuntimeError,'escaping or missing'):self.build()
        self.assertFalse(self.publication.exists())

    def test_receipt_poisoning_cannot_supply_trusted_cached_metadata(self):
        binary=self.build(); path=binary.parent/'receipt.json'
        data=json.loads(path.read_text());data['source']['files']['main.sh']['sha256']='0'*64
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError,'Changed Harbor producer receipt'):producer.verify(self.repo,binary)

    def test_staged_bytes_atomic_replacement_and_mode_changes_are_rejected(self):
        binary=self.build(); original=binary.read_bytes(); info=binary.stat()
        binary.write_bytes(b'X'+original[1:]);os.utime(binary,ns=(info.st_atime_ns,info.st_mtime_ns))
        with self.assertRaisesRegex(RuntimeError,'Changed staged'):producer.verify(self.repo,binary)
        binary.write_bytes(original);binary.chmod(0o700)
        other=binary.with_name('replacement');other.write_bytes(b'Y'+original[1:]);other.chmod(0o700);other.replace(binary)
        with self.assertRaisesRegex(RuntimeError,'Changed staged'):producer.verify(self.repo,binary)
        binary.write_bytes(original);binary.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError,'Invalid staged'):producer.verify(self.repo,binary)

    def test_restored_mtime_source_mode_new_inventory_and_link_target_changes(self):
        link=self.repo/'link.sh';link.symlink_to('main.sh')
        binary=self.build(); source=self.repo/'main.sh';info=source.stat();original=source.read_bytes()
        source.write_bytes(b'X'+original[1:]);os.utime(source,ns=(info.st_atime_ns,info.st_mtime_ns))
        with self.assertRaisesRegex(RuntimeError,'source changed'):producer.verify(self.repo,binary)
        source.write_bytes(original);source.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError,'source changed'):producer.verify(self.repo,binary)
        source.chmod(0o644);fresh=self.build();(self.repo/'new-authored-input').write_text('source')
        with self.assertRaisesRegex(RuntimeError,'source changed'):producer.verify(self.repo,fresh)
        (self.repo/'new-authored-input').unlink();source.write_text('#!/bin/sh\nprintf LINK_EDIT\n')
        with self.assertRaisesRegex(RuntimeError,'source changed'):producer.verify(self.repo,fresh)

    def test_actual_own_interface_imports_recipe_and_ignores_source_mentions(self):
        recipe=self.repo/'repro.nim'
        recipe.write_text(recipe.read_text()+'\n# executable ah:\nconst mentionedExport = "executable ah:"\n')
        original=(self.repo/'Justfile').read_text()
        (self.repo/'imported.just').write_text('build-rust-unit-test-binaries:\n    python3 build.py\n')
        (self.repo/'Justfile').write_text(original.split('build-rust-unit-test-binaries:')[0]+"import 'imported.just'\n")
        selection=self.publication.parent/'producer-interface.json'
        producer.select(self.repo,selection)
        data=json.loads(selection.read_text())
        self.assertEqual(data['interface'],'own')
        self.assertEqual(data['query'],['repro','exec','--','./dev-bin/just','--show','build-rust-unit-test-binaries'])
        self.assertEqual(subprocess.check_output([self.build()],text=True),'CURRENT_SOURCE')
        # A source mention alone never supplies the owning command interface.
        (self.repo/'Justfile').write_text(original.split('build-rust-unit-test-binaries:')[0]+'# build-rust-unit-test-binaries:\nother:\n    true\n')
        producer.select(self.repo,selection)
        self.assertEqual(json.loads(selection.read_text())['interface'],'export')

    def test_unknown_just_and_environment_query_errors_do_not_select_export(self):
        selection=self.publication.parent/'producer-interface.json'
        (self.repo/'Justfile').write_text('not valid ???\n')
        with self.assertRaisesRegex(RuntimeError,'interface query failed'):producer.select(self.repo,selection)
        self.assertFalse(selection.exists())
        (self.repo/'repro.nim').write_text('this is not valid Nim ???\n')
        with self.assertRaisesRegex(RuntimeError,'interface query failed'):producer.select(self.repo,selection)
        self.assertFalse(selection.exists())

    def test_ignored_authored_input_and_internal_directory_alias_are_bound(self):
        (self.repo/'src').mkdir()
        (self.repo/'.gitignore').write_text('.repro/\nsrc/ignored.inc\n')
        source=self.repo/'src/ignored.inc';source.write_text('actual compiled input')
        (self.repo/'alias-src').symlink_to('src',target_is_directory=True)
        binary=self.build()
        self.assertEqual(producer.verify(self.repo,binary),binary)
        self.assertIn(b'actual compiled input',binary.read_bytes())
        source.write_text('changed compiled input')
        with self.assertRaisesRegex(RuntimeError,'source changed'):producer.verify(self.repo,binary)
        current=self.build()
        self.assertIn(b'changed compiled input',current.read_bytes())
        self.assertNotEqual(producer.digest(current),producer.digest(binary))

    def test_ignored_authored_asset_outside_source_roots_is_bound(self):
        (self.repo/'assets').mkdir()
        (self.repo/'.gitignore').write_text('.repro/\nassets/input.inc\n')
        asset=self.repo/'assets/input.inc';asset.write_text('asset compiled before')
        binary=self.build()
        self.assertIn(b'asset compiled before',binary.read_bytes())
        selection=self.publication.parent/'producer-interface.json'
        producer.select(self.repo,selection)
        asset.write_text('asset compiled after')
        with self.assertRaisesRegex(RuntimeError,'source changed after producer query'):
            self.build()
        selection.unlink()
        with self.assertRaisesRegex(RuntimeError,'source changed'):
            producer.verify(self.repo,binary)
        current=self.build()
        self.assertIn(b'asset compiled after',current.read_bytes())
        self.assertNotEqual(producer.digest(binary),producer.digest(current))
        (self.repo/'change-asset-during-build').touch()
        self.publication.unlink()
        with self.assertRaisesRegex(RuntimeError,'source changed during build'):
            self.build()
        self.assertFalse(self.publication.exists())

    def test_symlinked_checkout_is_same_source_but_cache_and_escaping_stage_are_rejected(self):
        binary=self.build();alias=self.root/'linked-harbor';alias.symlink_to(self.repo,target_is_directory=True)
        self.assertEqual(producer.verify(alias,binary),binary)
        with self.assertRaisesRegex(RuntimeError,'Escaping'):producer.verify(self.repo,self.output)
        binary.unlink();binary.symlink_to(self.repo/'build/bin/ah')
        with self.assertRaisesRegex(RuntimeError,'Escaping'):producer.verify(self.repo,binary)


if __name__=='__main__':unittest.main()
