# 手机中继（Phone Relay）

在手机浏览器里查看、操作 Mac 上 Wireline 的终端会话：看 AI CLI 在干什么、等你确认时回一个 `y`。思路来自 Pebrel 的手机中继。不做原生 App，手机端是中继服务器托管的单页 Web 客户端。

## 架构

```
 Mac (Wireline)  ──wss──▶  Relay (自建, relay/)  ◀──wss──  手机浏览器 (relay/web)
   持有私钥，                  只按 room 转发密文，            扫码拿到 Mac 公钥，
   主动外连，不开端口           不解密、不落盘                  本地生成自己的密钥
```

- Mac 和手机都是**出站** WebSocket 连接到中继；Mac 不监听任何端口，不需要公网 IP / 端口转发。
- 中继以 **room** 为单位：`room = base64url(SHA256(Mac 公钥))[:22]`。每个 room 至多一个 Mac 连接、若干手机连接（默认 4）。
- 中继只认外层信封（谁发给谁），载荷是端到端密文；不存任何数据，进程重启即清空。
- 中继同时托管 `relay/web/index.html`，手机扫码直接打开同一个域名（WebCrypto 要求安全上下文，生产必须 HTTPS）。

## 外层协议（中继看得到的部分）

连接：`GET /ws?room=<room>&role=mac|phone`，`role=mac` 时若中继设置了 `RELAY_TOKEN`，需带 `&token=`。

文本帧 JSON：

| 方向 | 帧 | 说明 |
|---|---|---|
| 中继→Mac | `{"t":"join","peer":"p7"}` / `{"t":"leave","peer":"p7"}` | 手机上线 / 下线 |
| 手机→中继 | `{"d":"<b64>"}` | 中继改写成 `{"from":"p7","d":…}` 发给 Mac |
| Mac→中继 | `{"to":"p7","d":"<b64>"}` | 发给某台手机 |
| Mac→中继 | `{"t":"kick","peer":"p7"}` | 断开某台手机（撤销/握手失败） |
| 中继→手机 | `{"d":"<b64>"}` / `{"t":"mac","up":bool}` | 数据 / Mac 在线状态 |

## 配对

1. 设置页「手机中继」点「配对新设备」：生成一次性配对码（8 位，Crockford base32，5 分钟有效，单次使用，错 5 次作废），显示二维码：
   `https://<relay>/#v=1&k=<Mac 公钥 b64url>&c=<配对码>&n=<Mac 名称>`
   参数都在 `#` 片段里，浏览器不会把它发给中继。
2. 手机扫码打开页面：生成 X25519 密钥对（WebCrypto），连中继，发握手 `hello`（明文，见下），再发加密的 `pair{code,name}`。
3. Mac 校验配对码 → 记录手机公钥 + 名称（UserDefaults，公钥不敏感），回 `paired`。手机把自己的私钥（JWK）、Mac 公钥、中继地址存进 localStorage，之后打开页面自动重连。
4. 以后的连接：Mac 只接受已配对公钥的 `hello`；配对窗口打开时也接受未知公钥，但它在发出正确的 `pair` 之前只能收到 `error`。

中继无法冒充 Mac：手机的 Mac 公钥来自二维码（带外）。中继也拿不到配对码：它在 Mac 公钥加密的通道里传。

## 端到端加密

基元：X25519 + HKDF-SHA256 + AES-256-GCM（Mac 用 CryptoKit，浏览器用 WebCrypto，算法一一对应）。

握手（中继可见、不保密）：
- 手机→Mac：`{"t":"hello","v":1,"pub":"<手机公钥 b64>","nonce":"<16 字节 b64>"}`
- Mac→手机：`{"t":"welcome","nonce":"<16 字节 b64>"}`（未配对且不在配对窗口：`{"t":"deny"}` 并 kick）

会话密钥：
```
shared = X25519(mac_priv, phone_pub)            // 双方相同
salt   = phone_nonce || mac_nonce
info   = "wireline-relay v1" || mac_pub || phone_pub
key    = HKDF-SHA256(shared, salt, info, 32)
```
两端的随机 nonce 让每条连接的密钥不同，旧连接的密文不能重放到新连接。

数据帧：`d = b64( counter(8 字节大端) || AES-GCM(ciphertext||tag) )`，IV = `dir(1) || 000000 || counter(8)`，`dir` Mac→手机为 1、手机→Mac 为 2，AAD = `"wireline-relay v1"`。发送方 counter 从 1 递增，接收方要求严格递增，否则丢弃并断开——防重放、防重排、两方向 IV 不撞。

已知取舍：两端都用长期静态密钥（Mac 私钥在 Keychain，手机私钥在 localStorage），**没有前向保密**；泄露 Mac 私钥 + 抓到历史流量可解密。可加一对临时 X25519 混入 HKDF 解决，见「待拍板」。

## 内层消息（加密后的 JSON）

手机→Mac：

| 消息 | 字段 | |
|---|---|---|
| `pair` | `code`, `name` | 配对 |
| `list` | | 要会话列表 |
| `watch` | `sid` | 订阅某会话：回 `snapshot` 后持续推 `out`；同一时间只订一个 |
| `input` | `sid`, `data`（UTF-8 文本） | 键入；单条 ≤ 4 KB |

Mac→手机：

| 消息 | 字段 | |
|---|---|---|
| `paired` | `mac` | 配对成功 |
| `error` | `message` | |
| `sessions` | `list[{id,title,agent?,state?,note?,busy}]` | 会话列表；agent 状态变化时主动推 |
| `snapshot` | `sid`, `data`（b64 原始字节） | 当前屏幕 + 近期回滚，xterm.js 直接 write |
| `out` | `sid`, `data`（b64） | 实时输出 |

`state` 取 `idle|working|needsYou|done`（来自 `CodingAgentTracker.State`，即灵动岛同一份），`note` 是 needsYou 的提示文字。

快照：Mac 侧对每个会话保留最近 256 KB 原始输出的环形缓冲，`watch` 时整段发出。原始字节在 xterm.js 里重放即得到当前画面（全屏 TUI 若缓冲开头截在序列中间，第一屏可能有残字，随后的重绘会盖掉）。后续可改用引擎的序列化快照。

## 限流

- 中继：每连接 200 帧/秒、1 MB/秒（令牌桶，超出断开）；单帧 ≤ 1 MB；每 room ≤ 4 台手机；总 room 数上限（默认 1000）；`role=mac` 可要求 `RELAY_TOKEN`。
- Mac：每台手机 `input` 30 条/秒；配对码错 5 次作废；握手 10 秒内未完成即 kick；输出推送按 50 ms 合批。

## 撤销

设置页列出已配对设备（名称、配对时间、上次在线），点「撤销」：从列表删除公钥，并对其在线连接发 `kick`。该手机之后的 `hello` 一律 `deny`。「重置密钥」会换 Mac 密钥对，所有设备一起失效（room 也随之改变）。

## 默认与权限

- 默认关闭。开启后才外连中继。
- 输入只接受已完成握手、且公钥在配对列表里的设备；未配对连接只能做 `pair`。
- 不经中继传主机列表、密码、文件；只有终端会话的输出和输入。

## 代码位置

- `relay/main.go`：中继（Go 标准库，自带 WebSocket 实现），`relay/Dockerfile`，`relay/README.md`。
- `relay/web/index.html`：手机端（xterm.js CDN）。
- `Sources/WirelineCore/RelayProtocol.swift`：握手、密钥派生、帧加解密、消息编解码、配对码、配对链接、限流器（纯逻辑，有单测）。
- `Sources/Wireline/PhoneRelay.swift`：中继客户端、会话桥接、设置页一节。

## 待拍板

1. 是否加临时密钥做前向保密（协议 v2）。
2. 手机私钥放 localStorage（可导出 JWK）还是 IndexedDB 里不可导出的 CryptoKey。
3. 手机端是否允许输入任意文本，还是只开放快捷键（y/n/Esc/Ctrl-C/回车）。
4. 中继是否强制 `RELAY_TOKEN`，以及是否给手机连接也加门槛（目前手机只靠 E2E 认证，任何人都能占 4 个手机名额做 DoS）。
