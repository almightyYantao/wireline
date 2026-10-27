# Wireline phone relay

Forwards end-to-end encrypted frames between a Mac running Wireline and its paired phones. It never sees plaintext and stores nothing. Design: `docs/design/phone-relay.md`.

## Run locally

```
cd relay
go run . -addr 127.0.0.1:8080 -web web -insecure-no-token
```

`-insecure-no-token` is for local testing only; without it the relay refuses to start unless `RELAY_TOKEN` is set.

Open `http://127.0.0.1:8080/` (WebCrypto works on `localhost`/`127.0.0.1` without TLS; a phone on the LAN needs HTTPS).

## Deploy (Linux)

```
docker build -t wireline-relay relay/
docker run -d --name wireline-relay --restart unless-stopped \
  -p 127.0.0.1:8080:8080 -e RELAY_TOKEN="$(openssl rand -base64 32)" wireline-relay
```

Put it behind TLS, e.g. Caddy:

```
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

`RELAY_TOKEN` is required: both the Mac and every phone must present it (`?token=`). In Wireline: Settings → Phone Relay → relay address `https://relay.example.com`, token = `RELAY_TOKEN`. The pairing QR code carries the token to the phone (in the URL fragment, which browsers don't send).

The token travels in the WebSocket URL's query string, so keep it out of access logs, e.g. in Caddy:

```
relay.example.com {
    log { format filter { request>uri query { delete token } } }
    reverse_proxy 127.0.0.1:8080
}
```

The token only gates who can use the relay (DoS / squatting); confidentiality and authentication come from the end-to-end encryption.

| Env | Default | |
|---|---|---|
| `RELAY_ADDR` | `:8080` | listen address |
| `RELAY_WEB` | `web` | phone client directory |
| `RELAY_TOKEN` | (required) | shared secret for Macs and phones |
| `RELAY_MAX_PHONES` | 4 | phones per room |
| `RELAY_MAX_ROOMS` | 1000 | rooms in total |

Limits per connection: 200 frames/s, 1 MB/s, 1 MB per frame.

## Interop check

`node relay/test/vector.mjs` prints the frame `RelayProtocolTests.testKnownAnswerMatchesWebCrypto` expects.
