import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';

import { createMpxLottie } from '../../mpx_lottie_core.mjs';
import { builtWasm } from './built_wasm.mjs';

/** Hand-authored 100x100, 30 fps, 60 frame animation (never a corpus file). */
export const fixtureJson = readFileSync(new URL('../fixture.json', import.meta.url));
export const fixtureGzip = gzipSync(fixtureJson);

export const skip = builtWasm().skip;

/** A fresh core over one of the built files: 'mpx_lottie.wasm' or '.nosimd.'. */
export async function coreOf(name = 'mpx_lottie.wasm', options = {}) {
  return createMpxLottie(readFileSync(join(builtWasm().dir, name)), options);
}
