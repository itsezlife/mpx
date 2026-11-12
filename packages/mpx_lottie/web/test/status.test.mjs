import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { MAX_EDGE, STATUS } from '../mpx_lottie_core.mjs';

const header = readFileSync(
  new URL('../../native/include/mpx_lottie.h', import.meta.url),
  'utf8',
);

/** The `MPX_LOTTIE_<NAME> = <n>` entries of the first enum of the header. */
function headerStatuses() {
  const block = /enum \{([^}]*)\};/.exec(header);
  assert.ok(block, 'the status enum is in mpx_lottie.h');
  const statuses = {};
  for (const [, name, value] of block[1].matchAll(/MPX_LOTTIE_([A-Z_]+)\s*=\s*(-?\d+)/g)) {
    statuses[name] = Number(value);
  }
  return statuses;
}

test('STATUS names every status of the header with the same number', () => {
  assert.deepEqual({ ...STATUS }, headerStatuses());
});

test('STATUS is frozen: a typo cannot invent a status at run time', () => {
  assert.ok(Object.isFrozen(STATUS));
});

test('the edge cap of the core is the one the header documents', () => {
  assert.match(header, new RegExp(`/\\* 1\\.\\.${MAX_EDGE} \\*/`));
});
