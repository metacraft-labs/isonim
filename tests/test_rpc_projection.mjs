// Execute actual compiler output against immutable pre-extraction outcomes.
// Native fault controls are justified in rpc_projection_sample.mjs.
// The oracles (tests/oracles/rpc_projection_{node,chromium}_isonim_context_headers.json,
// named after the header contract they record: the Isonim-Context request
// header, the Retry-After / Isonim-Commit projection) were captured with
// CAPTURE_RPC_PROJECTION_ORACLE from this fixture compiled, without
// -d:extractedRpcComposition, against the pre-extraction source: isonim
// 9465abe8 with the nil body writer fix and the header-contract patch applied
// (that patch as a file: git hash-object 20af5385af1fb968a045beeda5af4adb7a858a17),
// rawBrowserFetch still inline in nondet.nim. Against the a40b666 oracles they
// differ only in the context header's name, the two projected response headers
// and the 'extra-headers' / 'no-response-headers' modes; every trace, read
// count and dispatch count is unchanged.
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
else assert.deepEqual(actual,JSON.parse(await readFile('tests/oracles/rpc_projection_node_isonim_context_headers.json','utf8')),'immutable RPC pre-extraction outcome and Promise-turn oracle');
console.log('PASS Node native RPC projection '+process.version);
