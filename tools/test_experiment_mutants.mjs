// Real compiler and browser falsifiers. Sources are restored byte-for-byte even
// on failure; this runs sequentially, never alongside another source reader.
import {readFileSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const core='src/isonim/experiments.nim', serializer='src/isonim/ssr/serializer.nim';
function reject(path,mutate,command,args,diagnostic) {
  const before=readFileSync(path,'utf8');
  try {
    const after=mutate(before);assert.notEqual(after,before);
    writeFileSync(path,after);
    const child=spawnSync(command,args,{encoding:'utf8',maxBuffer:10*1024*1024});
    assert.notEqual(child.status,0,'mutation unexpectedly passed');
    assert.match(child.stdout+child.stderr,diagnostic);
    console.log('falsifying mutation rejected: '+diagnostic);
  } finally {writeFileSync(path,before);}
}
reject(core,s=>{
  const begin=s.indexOf('  static:\n',s.indexOf('proc useExperimentImpl'));
  const end=s.indexOf('  result = low(E)',begin);
  const block=s.slice(begin,end);
  const removed=s.slice(0,begin)+s.slice(end);
  return removed.replace('  const site = instantiationInfo', '  mixin weights, window\n  const key = experimentTypeKey[E]()\n'+block+'  const site = instantiationInfo');
},'nim',['c','--hints:off','--out:build/experiments/mutant','tests/test_experiment_registration.nim'],/registrationCount/);
reject(serializer,s=>s.replace('.replace("<", "\\\\u003c")',''),'bash',['tools/check_experiments.sh'],/script payload executed/);
reject('tools/isonim_manifest.mjs',s=>s.replace('const experiments = Object.create(null), routes = Object.create(null);','const experiments = {}, routes = {};'),
  'node',['tools/isonim_manifest.mjs','build/experiments/safe-js','build/experiments/app.js','build/experiments/safe-mutant.json','mutation'],/conflicting experiment metadata/);
reject(core,s=>s.replace('stableIid(experimentSource(file) &', 'stableIid(file &'),
  'node',['tests/test_experiment_relocation.mjs'],/equivalent checkout roots/);
// Rebuild after source restoration so delivered test artifacts are never mutant
// outputs, even when this target is run by itself.
const restored=spawnSync('bash',['tools/check_experiments.sh'],{stdio:'inherit'});
assert.equal(restored.status,0,'restored sources must pass');
