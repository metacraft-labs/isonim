// Real C/JS compiler relocation boundary; no mocked compiler or source paths.
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, renameSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';

const temporary = mkdtempSync(join(tmpdir(), 'isonim-experiment-relocation-'));
const repo = process.cwd();
const component = `import std/json
import isonim/experiments
import isonim/core/owner
type RelocationArm = enum control, treatment
proc readArm*(): string =
  let assignment = newExperimentAssignment()
  createRoot proc(dispose: proc()) =
    withExperiments(assignment):
      discard useExperiment[RelocationArm]()
    dispose()
  $experimentResource(assignment)
`;
try {
  const roots = ['first', 'second'].map(name => {
    const root = join(temporary, name);
    mkdirSync(root);
    writeFileSync(join(root, 'component.nim'), component);
    writeFileSync(join(root, 'app.nim'), 'import ./component\necho readArm()\n');
    return root;
  });
  function compile(root, backend, explicit, renamed = false) {
    const fragments = join(root, `${backend}-${explicit}-${renamed}`);
    mkdirSync(fragments);
    const output = join(fragments, backend === 'js' ? 'app.js' : 'app');
    const args = [backend, '--hints:off', '-d:release', '--stackTrace:off', '--lineTrace:off',
      '--path:' + resolve(repo, 'src'), '--path:' + resolve(repo, '../nim-everywhere/src'),
      '-d:experimentManifestDir=' + fragments, '--out:' + output];
    if (explicit) args.push('-d:experimentProjectRoot=' + root);
    execFileSync('nim', [...args, join(root, 'app.nim')], {stdio:'pipe'});
    const resource = JSON.parse(execFileSync(backend === 'js' ? 'node' : output,
      backend === 'js' ? [output] : [], {encoding:'utf8'}));
    const metadata = JSON.parse(readFileSync(join(fragments, 'experiments.json'), 'utf8'));
    const sites = Object.values(metadata.sites);
    assert.equal(sites.length, 1);
    assert.equal(resource.exposed.length, 1);
    assert.equal(resource.exposed[0].callSite, sites[0].id);
    assert.equal(sites[0].file, renamed ? 'renamed.nim' : 'component.nim');
    return {resource, metadata};
  }
  const baseline = compile(roots[0], 'c', true);
  for (const root of roots)
    for (const backend of ['c', 'js'])
      for (const explicit of [false, true]) {
        if (root === roots[0] && backend === 'c' && explicit) continue;
        assert.deepEqual(compile(root, backend, explicit), baseline,
          'equivalent checkout roots and C/JS must retain runtime/manifest identities');
      }
  renameSync(join(roots[1], 'component.nim'), join(roots[1], 'renamed.nim'));
  writeFileSync(join(roots[1], 'app.nim'), 'import ./renamed\necho readArm()\n');
  const renamed = compile(roots[1], 'js', true, true);
  assert.notEqual(renamed.resource.exposed[0].callSite, baseline.resource.exposed[0].callSite,
    'a different relative component must have a different identity');
  console.log('experiment relocation: C/JS, explicit/default roots and rename control passed');
} finally {
  rmSync(temporary, {recursive:true, force:true});
}
