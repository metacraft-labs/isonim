/** Close acceptance oracle shared by the actual browser and protocol controls. */
import assert from 'node:assert/strict';

export function assertCloseAcknowledgement(status, body) {
 assert.equal(status, 200, 'close must acknowledge HTTP 200');
 assert(body !== null && typeof body === 'object' && !Array.isArray(body),
  'close acknowledgment must be a JSON object');
 assert.equal(body.closed, true, 'close must acknowledge literal closed:true');
}
