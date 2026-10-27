// Prints the known-answer frame used by RelayProtocolTests.testKnownAnswerMatchesWebCrypto.
// node relay/test/vector.mjs
import { createPrivateKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

(0, eval)(readFileSync(fileURLToPath(new URL('../web/relay-crypto.js', import.meta.url)), 'utf8'));
const R = globalThis.WLRelay;
const keyOf = async (byte) => {
  const jwk = createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.alloc(32, byte)]),
    format: 'der', type: 'pkcs8',
  }).export({ format: 'jwk' });
  return { priv: await R.importPrivate(jwk), pub: R.unb64url(jwk.x) };
};

const ms = await keyOf(0x11), ps = await keyOf(0x22), me = await keyOf(0x33), pe = await keyOf(0x44);
const t = { macStatic: ms.pub, phoneStatic: ps.pub, macEph: me.pub, phoneEph: pe.pub,
            phoneNonce: new Uint8Array(16).fill(0xaa), macNonce: new Uint8Array(16).fill(0xbb) };
// Derived on the phone side, sealed as the Mac would: Swift must produce the same frame.
const key = await R.sessionKey(ps.priv, pe.priv, t, 'phone');
console.log(R.b64(await R.channel(key, 'mac').seal(R.enc.encode('hello phone'))));
