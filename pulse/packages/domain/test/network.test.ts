import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isNetworkFailure } from '../src/network.ts';

test('network failures are recognised in every browser\'s wording', () => {
  assert.equal(isNetworkFailure(new TypeError('Failed to fetch')), true);                                   // Chrome
  assert.equal(isNetworkFailure({ message: 'TypeError: NetworkError when attempting to fetch resource.' }), true); // Firefox (via postgrest-js)
  assert.equal(isNetworkFailure({ message: 'TypeError: Load failed', code: '' }), true);                    // Safari / iPhone
  assert.equal(isNetworkFailure({ name: 'StorageUnknownError', message: 'Load failed' }), true);            // photo upload on iPhone
  assert.equal(isNetworkFailure({ message: 'The network connection was lost.' }), true);
  assert.equal(isNetworkFailure(new Error('anything'), false), true);                                      // browser says offline
});

test('server refusals are not treated as offline', () => {
  assert.equal(isNetworkFailure({ message: 'not_friends', code: 'P0001' }), false);
  assert.equal(isNetworkFailure(new Error('rate_limited')), false);
  assert.equal(isNetworkFailure(null), false);
});
