# Wireline phone relay

Forwards end-to-end encrypted frames between a Mac running Wireline and its paired phones. It never sees plaintext and stores nothing. Design: `docs/design/phone-relay.md`.

## Run locally

```
cd relay
go run . -addr 127.0.0.1:8080 -web web
```

Open `http://127.0.0.1:8080/` (WebCrypto works on `localhost`/`127.0.0.1` without TLS; a phone on the LAN needs HTTPS).

## Deploy (Linux)

```
docker build -t wireline-relay relay/
docker run -d --name wireline-relay --restart unless-stopped \
  -p 127.0.0.1:8080:8080 -e RELAY_TOKEN=<long random> wireline-relay
```

Put it behind TLS, e.g. Caddy:

```
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

In Wireline: Settings → Phone Relay → relay address `https://relay.example.com`, token = `RELAY_TOKEN`.

| Env | Default | |
|---|---|---|
| `RELAY_ADDR` | `:8080` | listen address |
| `RELAY_WEB` | `web` | phone client directory |
| `RELAY_TOKEN` | (none) | required from Macs when set |
| `RELAY_MAX_PHONES` | 4 | phones per room |
| `RELAY_MAX_ROOMS` | 1000 | rooms in total |

Limits per connection: 200 frames/s, 1 MB/s, 1 MB per frame.

## Interop check

`node relay/test/vector.mjs` prints the frame `RelayProtocolTests.testKnownAnswerMatchesWebCrypto` expects.
