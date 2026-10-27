// Prints the known-answer frame used by RelayProtocolTests.testKnownAnswerMatchesWebCrypto.
// node relay/test/vector.mjs
import { createPrivateKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

(0, eval)(readFileSync(fileURLToPath(new URL('../web/relay-crypto.js', import.meta.url)), 'utf8'));
const R = globalThis.WLRelay;
const jwkOf = (byte) => createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.alloc(32, byte)]),
  format: 'der', type: 'pkcs8',
}).export({ format: 'jwk' });

const mac = jwkOf(0x11), phone = jwkOf(0x22);
const macPub = R.unb64url(mac.x), phonePub = R.unb64url(phone.x);
const key = await R.sessionKey(phone, macPub, phonePub, new Uint8Array(16).fill(0xaa), new Uint8Array(16).fill(0xbb));
console.log(R.b64(await R.channel(key, 'mac').seal(R.enc.encode('hello phone'))));
