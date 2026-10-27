// Phone web client: pairing, handshake, session list, terminal, quick keys.
(async () => {
  const R = window.WLRelay, $ = (id) => document.getElementById(id);
  const STORE = 'wireline.relay';
  const status = (s) => { $('status').textContent = s; };

  // Pairing link: #v=1&k=<mac pub>&c=<code>&n=<name>&t=<relay token>. The fragment never reaches the server.
  // localStorage holds only public values; the private key lives in IndexedDB.
  let saved = JSON.parse(localStorage.getItem(STORE) || 'null');
  let stored = await R.keystore.get();
  if (saved && saved.priv) {
    // Migrate an old extractable JWK: re-import as non-extractable, then drop it.
    if (!stored) { stored = { privateKey: await R.importPrivate(saved.priv), pub: saved.pub }; await R.keystore.put(stored); }
    delete saved.priv;
    localStorage.setItem(STORE, JSON.stringify(saved));
  }
  let pairCode = null;
  const frag = new URLSearchParams(location.hash.slice(1));
  if (frag.get('v') === '1' && frag.get('k')) {
    if (!stored || !saved || saved.mac !== frag.get('k')) {
      const k = await R.generateKeys();
      stored = { privateKey: k.privateKey, pub: R.b64(k.publicRaw) };
      await R.keystore.put(stored);
    }
    saved = { pub: stored.pub, mac: frag.get('k'), name: frag.get('n') || 'Mac', token: frag.get('t') || '', paired: false };
    pairCode = frag.get('c');
    localStorage.setItem(STORE, JSON.stringify(saved));
    history.replaceState(null, '', location.pathname);
  }
  if (!saved || !stored) { $('pair').style.display = 'block'; return; }
  $('macName').textContent = saved.name;
  $('forget').classList.remove('hidden');
  $('forget').onclick = async () => { localStorage.removeItem(STORE); await R.keystore.clear(); location.reload(); };

  const macPub = R.unb64url(saved.mac), phonePub = R.unb64(saved.pub);
  const room = await R.roomID(macPub);
  const term = new Terminal({ fontSize: 12, convertEol: false, scrollback: 5000, theme: { background: '#0f1115' } });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);

  const staticKey = stored.privateKey;
  let ws, ch, myNonce, myEph, current = null, sessions = [];
  // WebCrypto is async: keep frames in counter order both ways.
  let outQ = Promise.resolve(), inQ = Promise.resolve();
  const send = (msg) => { outQ = outQ.then(async () => {
    if (!ch || ws.readyState !== 1) return;
    const c = ch, frame = await c.seal(R.enc.encode(JSON.stringify(msg)));
    if (c === ch) ws.send(JSON.stringify({ d: R.payload.sealed(frame) }));
  }).catch(() => {}); };
  const input = (data) => current && send({ t: 'input', sid: current, data });
  // Quick keys only until the Mac allows full input (it enforces this too).
  let fullInput = false;
  term.onData((d) => fullInput && input(d));

  function render() {
    const box = $('sessions'); box.innerHTML = '';
    for (const s of sessions) {
      const row = document.createElement('div');
      row.className = 's' + (s.id === current ? ' active' : '');
      const t = document.createElement('span'); t.className = 't'; t.textContent = s.title;
      row.append(t);
      if (s.agent || s.busy) {
        const b = document.createElement('span');
        b.className = 'badge ' + (s.state || '');
        b.textContent = (s.agent ? s.agent + ' · ' : '') + ({ idle: '空闲', working: '工作中', needsYou: '等你确认', done: '完成' }[s.state] || '运行中');
        row.append(b);
      }
      row.onclick = () => watch(s.id);
      box.append(row);
    }
    const cur = sessions.find((s) => s.id === current);
    $('note').textContent = cur && cur.state === 'needsYou' ? (cur.note || '等你确认') : '';
  }

  function watch(sid) {
    current = sid; term.reset(); render(); send({ t: 'watch', sid });
  }

  async function onMessage(m) {
    switch (m.t) {
      case 'paired':
        saved.paired = true; localStorage.setItem(STORE, JSON.stringify(saved));
        send({ t: 'list' }); break;
      case 'sessions':
        sessions = m.list || [];
        if (!current) {
          const waiting = sessions.find((s) => s.state === 'needsYou') || sessions[0];
          if (waiting) watch(waiting.id);
        }
        render(); break;
      case 'snapshot': if (m.sid === current) { term.reset(); term.write(R.unb64(m.data)); } break;
      case 'out': if (m.sid === current) term.write(R.unb64(m.data)); break;
      case 'policy': fullInput = !!m.full; $('line').classList.toggle('hidden', !fullInput); break;
      case 'error': status(m.message); break;
    }
  }

  let retry = 1000;
  function connect() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(`${proto}//${location.host}${location.pathname.replace(/[^/]*$/, '')}ws?room=${room}&role=phone` +
      (saved.token ? `&token=${encodeURIComponent(saved.token)}` : ''));
    ch = null;
    status('连接中…');
    ws.onmessage = (ev) => { inQ = inQ.then(() => handle(ev)).catch(() => {}); };
    const handle = async (ev) => {
      const e = JSON.parse(ev.data);
      if (e.t === 'mac') {
        $('dot').classList.toggle('on', e.up);
        if (e.up) {
          // Fresh ephemeral per connection: forward secrecy.
          myNonce = R.nonce(); myEph = await R.generateKeys();
          ws.send(JSON.stringify({ d: R.payload.handshake({ t: 'hello', v: R.VERSION, pub: saved.pub,
                                                             epub: R.b64(myEph.publicRaw), nonce: R.b64(myNonce) }) }));
          status('握手中…');
        }
        else { ch = null; status('Mac 离线'); }
        return;
      }
      if (e.t === 'full') { status('中继已满'); return; }
      if (!e.d) return;
      const p = R.payload.parse(e.d);
      if (p.handshake) {
        if (p.handshake.t === 'deny') { status('Mac 拒绝：未配对或已撤销'); return; }
        if (p.handshake.t !== 'welcome' || ch) return;
        const key = await R.sessionKey(staticKey, myEph.privateKey, {
          macStatic: macPub, phoneStatic: phonePub, macEph: R.unb64(p.handshake.epub), phoneEph: myEph.publicRaw,
          phoneNonce: myNonce, macNonce: R.unb64(p.handshake.nonce) }, 'phone');
        myEph = null;
        ch = R.channel(key, 'phone');
        retry = 1000;
        status('已连接');
        $('main').classList.remove('hidden');
        if (!term.element) { term.open($('term')); fit.fit(); }
        if (!saved.paired && pairCode) send({ t: 'pair', code: pairCode, name: navigator.platform || 'Phone' });
        else send({ t: 'list' });
        return;
      }
      if (p.sealed && ch) {
        try { await onMessage(JSON.parse(R.dec.decode(await ch.open(p.sealed)))); }
        catch { status('解密失败，重连'); ws.close(); }
      }
    };
    ws.onclose = () => { ch = null; $('dot').classList.remove('on'); status('已断开，重连中…'); setTimeout(connect, retry); retry = Math.min(retry * 2, 30000); };
  }
  connect();

  for (const b of document.querySelectorAll('#keys button')) b.onclick = () => input(b.dataset.k);
  $('line').onkeydown = (e) => { if (e.key === 'Enter') { input(e.target.value + '\r'); e.target.value = ''; } };
  addEventListener('resize', () => term.element && fit.fit());
})();
