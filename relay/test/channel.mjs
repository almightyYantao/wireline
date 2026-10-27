// Phone/Mac channel round trip in WebCrypto alone (no relay).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

(0, eval)(readFileSync(fileURLToPath(new URL('../web/relay-crypto.js', import.meta.url)), 'utf8'));
const R = globalThis.WLRelay;
const a = await R.generateKeys(), b = await R.generateKeys();
const n1 = R.nonce(), n2 = R.nonce();
const km = await R.sessionKey(a.privateJwk, b.publicRaw, a.publicRaw, b.publicRaw, n1, n2);
const kp = await R.sessionKey(b.privateJwk, a.publicRaw, a.publicRaw, b.publicRaw, n1, n2);
// The relay can't splice a frame across connections: other nonces, other key.
const other = R.channel(await R.sessionKey(b.privateJwk, a.publicRaw, a.publicRaw, b.publicRaw, n1, R.nonce()), 'phone');
await assert.rejects(async () => other.open(await R.channel(km, 'mac').seal(R.enc.encode('x'))));
const m = R.channel(km, 'mac'), p = R.channel(kp, 'phone');
const viaPayload = (f) => R.payload.parse(R.payload.sealed(f)).sealed;
assert.equal(R.dec.decode(await p.open(viaPayload(await m.seal(R.enc.encode('hi'))))), 'hi');
assert.equal(R.dec.decode(await m.open(viaPayload(await p.seal(R.enc.encode('yo'))))), 'yo');
console.log('channel ok');
