// Handshake + channel round trip in WebCrypto alone (no relay).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

(0, eval)(readFileSync(fileURLToPath(new URL('../web/relay-crypto.js', import.meta.url)), 'utf8'));
const R = globalThis.WLRelay;
const ms = await R.generateKeys(), ps = await R.generateKeys();
async function handshake(phoneStatic = ps) {
  const me = await R.generateKeys(), pe = await R.generateKeys();
  const t = { macStatic: ms.publicRaw, phoneStatic: ps.publicRaw, macEph: me.publicRaw, phoneEph: pe.publicRaw,
              phoneNonce: R.nonce(), macNonce: R.nonce() };
  return [R.channel(await R.sessionKey(ms.privateKey, me.privateKey, t, 'mac'), 'mac'),
          R.channel(await R.sessionKey(phoneStatic.privateKey, pe.privateKey, t, 'phone'), 'phone')];
}

const [m, p] = await handshake();
const viaPayload = (f) => R.payload.parse(R.payload.sealed(f)).sealed;
assert.equal(R.dec.decode(await p.open(viaPayload(await m.seal(R.enc.encode('hi'))))), 'hi');
assert.equal(R.dec.decode(await m.open(viaPayload(await p.seal(R.enc.encode('yo'))))), 'yo');

// Another connection (other ephemerals) can't open this one's frames.
const [, p2] = await handshake();
await assert.rejects(async () => p2.open(await m.seal(R.enc.encode('x'))));
// Without the phone's static key the keys don't match.
const [m3, p3] = await handshake(await R.generateKeys());
await assert.rejects(async () => p3.open(await m3.seal(R.enc.encode('x'))));
// Static keys are non-extractable.
await assert.rejects(() => crypto.subtle.exportKey('jwk', ps.privateKey));
console.log('channel ok');
