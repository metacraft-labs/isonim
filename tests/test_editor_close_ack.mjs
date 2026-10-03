/** Constructed protocol inputs test the exact oracle used on the real response.
 * No browser, provider or HTTP object is mocked. The separate required real GUI
 * gate obtains/parses the actual close response and proves actual SDK reaping.
 */
import assert from 'node:assert/strict';
import {assertCloseAcknowledgement} from './helpers/editor_close_ack.mjs';

assertCloseAcknowledgement(200, JSON.parse('{"closed":true}'));
for (const body of [
 {closed:false}, {}, null, [], {closed:'true'}, {closed:1}, {closed:{}},
]) {
 assert.throws(()=>assertCloseAcknowledgement(200,body),
  {name:'AssertionError'}, 'invalid close body must fail');
}
assert.throws(()=>assertCloseAcknowledgement(500,{closed:true}),{name:'AssertionError'});
assert.throws(()=>assertCloseAcknowledgement(200,JSON.parse('{"closed":')),
 {name:'SyntaxError'}, 'malformed response JSON must fail before acknowledgment');
console.log('PASS close ACK: literal true and 9 invalid response controls');
