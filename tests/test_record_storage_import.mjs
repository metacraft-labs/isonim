/** Actual Node windowless execution of the compiled private import. A bounded
 * require sentinel witnesses forbidden eager owner loading; it supplies no
 * module, Window, Recorder or platform provider. The real browser production
 * tests separately construct and use the actual owner. */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const code=readFileSync(process.argv[2],'utf8');let loads=0;
const context=vm.createContext({require(){loads++;throw new Error('forbidden eager owner module load');},console});
vm.runInContext(code,context,{filename:process.argv[2]});
assert.equal(loads,0,'actual compiled private import does not load owner');
assert.equal(vm.runInContext('typeof window',context),'undefined','actual windowless context');
console.log('storage private import: actual windowless execution / zero owner loads');
