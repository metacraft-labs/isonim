// Execute actual compiler output against immutable pre-extraction outcomes.
// Native fault controls are justified in rpc_projection_sample.mjs.
import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import vm from 'node:vm';
import {rpcModes,rpcSample} from './rpc_projection_sample.mjs';
vm.runInThisContext(await readFile(process.env.RPC_PROJECTION_FIXTURE ?? 'build/rpc_projection_fixture.js','utf8'));
const actual={};
for(const path of ['facade','raw']) {
  actual[path]={};
  for(const mode of rpcModes)actual[path][mode]=await rpcSample(rpcProbe,path,mode);
}
if(rpcProbe.composition)for(const mode of rpcModes)
  assert.deepEqual(await rpcSample(rpcProbe,'composition',mode),actual.raw[mode],'RPC extracted composition parity '+mode);
if(process.env.CAPTURE_RPC_PROJECTION_ORACLE)await writeFile(process.env.CAPTURE_RPC_PROJECTION_ORACLE,JSON.stringify(actual,null,2)+'\n');
else assert.deepEqual(actual,JSON.parse(await readFile('tests/oracles/rpc_projection_node_a40b666.json','utf8')),'immutable RPC pre-extraction outcome and Promise-turn oracle');
console.log('PASS Node native RPC projection '+process.version);
