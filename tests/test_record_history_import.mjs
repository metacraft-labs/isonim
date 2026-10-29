/** Windowless import rejects any owner resolution attempt; uncalled constructor
 * is retained without manufacturing browser objects or replacing owner classes. */
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
let loads=0;const context=vm.createContext({console,require(){loads++;throw Error('unexpected owner load');}});
vm.runInContext(readFileSync(process.argv[2],'utf8'),context);
assert.equal(loads,0);console.log('history windowless import zero owner loads PASS');
