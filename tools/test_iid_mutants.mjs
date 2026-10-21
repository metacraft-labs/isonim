// Mutation controls run serially and restore the implementation in finally.
// A failed compile is accepted only for the deliberate collision mutation;
// behavioral mutations must fail their actual assertion, not a build step.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const file='src/isonim/dsl/stable_ids.nim';
const source=readFileSync(file,'utf8');
mkdirSync('build/iid-mutants',{recursive:true});
function run(name, mutated, command, args, discriminates) {
  assert.notEqual(mutated,source,'mutation must change source');
  writeFileSync(file,mutated);
  try {
    const result=spawnSync(command,args,{encoding:'utf8'});
    const output=(result.stdout||'')+(result.stderr||'');
    writeFileSync(`build/iid-mutants/${name}.log`,output);
    assert.notEqual(result.status,0,`${name} stayed green`);
    assert(discriminates(output),`${name} failed for an unrelated reason:\n${output}`);
    console.log(`${name} RED as required`);
  } finally {writeFileSync(file,source);}
}
run('line-position',source.replace('let identity = component & nextPath','let identity = component & nextPath & ":" & $child.lineInfoObj.line'),
  'nim',['c','-r','--hints:off','--out:build/test_iid_stability','tests/test_iid_stability.nim'],
  out=>out.includes('[FAILED] unrelated lines and another component do not change identities'));
run('structural-collision',source.replace('let identity = component & nextPath','let identity = component & "/forced"'),
  'bash',['tools/check_manifest.sh'],out=>out.includes('stable iid collision:'));
run('authored-iid',source.replace('attributeName(arg[0]).toLowerAscii == "data-iid"', 'attributeName(arg[0]).toLowerAscii == "never-reserved-data-iid"'),
  'nim',['c','-r','--hints:off','--out:build/test_iid_stability','tests/test_iid_stability.nim'],
  out=>out.includes('[FAILED] authored data-iid is reserved across real renderers only with stable ids') &&
    out.includes('Check failed: rejected.exitCode != 0'));
run('authored-iid-case',source.replace('attributeName(arg[0]).toLowerAscii == "data-iid"', 'attributeName(arg[0]) == "data-iid"'),
  'nim',['c','-r','--hints:off','--out:build/test_iid_stability','tests/test_iid_stability.nim'],
  out=>out.includes('[FAILED] authored data-iid is reserved across real renderers only with stable ids') &&
    out.includes('Check failed: rejected.exitCode != 0'));
run('backend-hash',source.replace('proc position(node:', '  when defined(js): result[0] = (if result[0] == \'a\': \'b\' else: \'a\')\n\nproc position(node:'),
  'bash',['tools/check_manifest.sh'],out=>out.includes('--- ') && out.includes('+++ ') && out.includes('"iids"'));
run('instance-scope',source.replace('stableInstancePath.add("@" & scope)', 'discard scope'),
  'nim',['c','-r','--hints:off','--out:build/test_iid_instances','tests/test_iid_instances.nim'],
  out=>out.includes('[FAILED] repeated nested instances are unique and source-line independent') &&
    out.includes('duplicate live stable iid:'));
// Leave normal artifacts behind, never the final mutant's bundle.
const normal=spawnSync('bash',['tools/check_manifest.sh'],{stdio:'inherit'});
assert.equal(normal.status,0,'normal manifest must recover after mutants');
