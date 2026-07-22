# dms-darwin

A macOS daemon speaking the [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
daemon protocol (`$DMS_SOCKET`), so the **unmodified** shell gets its system
integrations from native macOS backends. The upstream Go daemon owns Linux;
this one owns macOS.

JSON lines over a unix socket, two connection kinds:

- request: `{"id", "method", "params"}` → `{"id", "result" | "error"}`
- subscribe: `{"method": "subscribe", "params": {"clientId", "services"?}}`
  → stream of `{"result": {"service", "data"}}`, seeded with the
  `server` handshake (`apiVersion`, `cliVersion`, `capabilities`).

## Services

| Service | Backend | Status |
|---|---|---|
| `brightness` | DisplayServices (built-in panel) | ✅ getState / setBrightness / increment / decrement / rescan, subscription pushes, external-change polling |

More channels (night mode, clipboard, network, ...) land service by service.

## Install

```sh
Scripts/install.sh   # builds release, installs ~/.local/bin/dms-darwin,
                     # (re)starts the launchd agent dev.dms
```

Log: `/tmp/dms-darwin.log` · Socket: `/tmp/dms-darwin.sock` (override with
`DMS_SOCKET`).

## Development

```sh
swift build && .build/debug/dms-darwin selftest
```
