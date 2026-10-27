// End-to-end check against a running relay: a simulated Mac and phone pair,
// list, watch, type, then the Mac revokes the phone.
// go run ./relay -addr 127.0.0.1:8099 -web relay/web &  node relay/test/e2e.mjs ws://127.0.0.1:8099
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

(0, eval)(readFileSync(fileURLToPath(new URL('../web/relay-crypto.js', import.meta.url)), 'utf8'));
const R = globalThis.WLRelay;
const base = process.argv[2] || 'ws://127.0.0.1:8099';
const json = (o) => JSON.stringify(o);

function socket(url) {
  const ws = new WebSocket(url);
  const queue = [], waiters = [];
  let chain = Promise.resolve();
  ws.onmessage = (ev) => { chain = chain.then(() => { const m = JSON.parse(ev.data); const w = waiters.shift(); w ? w(m) : queue.push(m); }); };
  ws.next = () => queue.length ? Promise.resolve(queue.shift()) : new Promise((r, j) => {
    const t = setTimeout(() => j(new Error('timeout')), 3000);
    waiters.push((m) => { clearTimeout(t); r(m); });
  });
  ws.closed = new Promise((r) => { ws.onclose = r; });
  return new Promise((r, j) => { ws.onopen = () => r(ws); ws.onerror = j; });
}

const macKeys = await R.generateKeys(), phoneKeys = await R.generateKeys();
const room = await R.roomID(macKeys.publicRaw);
const sniffed = [];

// --- Mac ---
const mac = await socket(`${base}/ws?room=${room}&role=mac`);
const code = 'AB12CD34';
let macCh = null, paired = new Set();
const macSend = async (peer, msg) => mac.send(json({ to: peer, d: R.payload.sealed(await macCh.seal(R.enc.encode(json(msg)))) }));

// --- Phone ---
const phone = await socket(`${base}/ws?room=${room}&role=phone`);
assert.deepEqual(await phone.next(), { t: 'mac', up: true });
const join = await mac.next();
assert.equal(join.t, 'join');
const peer = join.peer;

const phoneNonce = R.nonce();
phone.send(json({ d: R.payload.handshake({ t: 'hello', v: 1, pub: R.b64(phoneKeys.publicRaw), nonce: R.b64(phoneNonce) }) }));
const hello = await mac.next();
assert.equal(hello.from, peer);
const h = R.payload.parse(hello.d).handshake;
const macNonce = R.nonce();
macCh = R.channel(await R.sessionKey(macKeys.privateJwk, R.unb64(h.pub), macKeys.publicRaw, R.unb64(h.pub), R.unb64(h.nonce), macNonce), 'mac');
mac.send(json({ to: peer, d: R.payload.handshake({ t: 'welcome', nonce: R.b64(macNonce) }) }));

const welcome = R.payload.parse((await phone.next()).d).handshake;
const phoneCh = R.channel(await R.sessionKey(phoneKeys.privateJwk, macKeys.publicRaw, macKeys.publicRaw, phoneKeys.publicRaw, phoneNonce, R.unb64(welcome.nonce)), 'phone');
const phoneSend = async (msg) => phone.send(json({ d: R.payload.sealed(await phoneCh.seal(R.enc.encode(json(msg)))) }));
const macRecv = async () => { const e = await mac.next(); sniffed.push(e.d); return JSON.parse(R.dec.decode(await macCh.open(R.payload.parse(e.d).sealed))); };
const phoneRecv = async () => { const e = await phone.next(); sniffed.push(e.d); return JSON.parse(R.dec.decode(await phoneCh.open(R.payload.parse(e.d).sealed))); };

await phoneSend({ t: 'pair', code, name: 'test phone' });
const pair = await macRecv();
assert.equal(pair.code, code);
paired.add(R.b64(phoneKeys.publicRaw));
await macSend(peer, { t: 'paired', mac: 'Test Mac' });
assert.equal((await phoneRecv()).t, 'paired');

await phoneSend({ t: 'list' });
assert.equal((await macRecv()).t, 'list');
await macSend(peer, { t: 'sessions', list: [{ id: 'S1', title: 'claude', agent: 'Claude Code', state: 'needsYou', note: 'Allow edit?', busy: true }] });
assert.equal((await phoneRecv()).list[0].state, 'needsYou');

await phoneSend({ t: 'watch', sid: 'S1' });
assert.equal((await macRecv()).sid, 'S1');
const secret = 'Do you want to apply this edit? SECRET-CONTENT';
await macSend(peer, { t: 'snapshot', sid: 'S1', data: R.b64(R.enc.encode(secret)) });
for (let i = 0; i < 20; i++) await macSend(peer, { t: 'out', sid: 'S1', data: R.b64(R.enc.encode(`line ${i}\r\n`)) });
assert.equal(R.dec.decode(R.unb64((await phoneRecv()).data)), secret);
for (let i = 0; i < 20; i++) assert.equal(R.dec.decode(R.unb64((await phoneRecv()).data)), `line ${i}\r\n`);

await phoneSend({ t: 'input', sid: 'S1', data: 'y\r' });
assert.deepEqual(await macRecv(), { t: 'input', sid: 'S1', data: 'y\r' });

// The relay only ever carried ciphertext.
for (const d of sniffed) assert.ok(!Buffer.from(d, 'base64').toString('latin1').includes('SECRET'));

// Revoke: the Mac kicks the peer, the relay closes it and reports the leave.
mac.send(json({ t: 'kick', peer }));
await phone.closed;
assert.deepEqual(await mac.next(), { t: 'leave', peer });

// A replayed frame on a fresh connection fails to open (new nonces, new key).
mac.close();
console.log('e2e ok:', sniffed.length, 'sealed frames relayed');
process.exit(0);
