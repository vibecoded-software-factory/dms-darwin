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

Announced capabilities (live handshake): `plugins`, `brightness`, `gamma`,
`freedesktop`, `bluetooth`.

| Service | Backend | Status |
|---|---|---|
| `brightness` | DisplayServices (built-in panel) | ✅ getState / setBrightness / increment / decrement / rescan, subscription pushes, external-change polling |
| `gamma` (night mode) | Night Shift + a suncalc port | ✅ all six `wayland.gamma.*` methods the shell calls |
| `freedesktop` | OpenDirectory / portal analogues | ✅ accounts (avatar) + settings (color scheme), screensaver channel |
| `bluetooth` | IOBluetooth pairing delegate | ✅ daemon-side `bluetooth.pair` / `pairing.submit` / `pairing.cancel` (device listing lives in bento's `Quickshell.Bluetooth`) |
| `plugins` | local registry | ✅ the five `plugins.*` methods PluginService calls (`~/.config/DankMaterialShell/plugins`) |

Extra subcommands beside `serve`: `lock` (native session lock, wired to the
shell's `customPowerActionLock` setting), `audio-tap` (system-audio tap
feeding the visualizer fifo), `selftest`, `version`.

## Install

```sh
Scripts/install.sh   # builds release, installs ~/.local/bin/dms-darwin,
                     # (re)starts the launchd agent dev.dms
```

Log: `/tmp/dms-darwin.log` · Socket: `/tmp/dms-darwin.sock` (override with
`DMS_SOCKET`).

## Shell glue (Glue/)

`Glue/install.sh` / `Glue/uninstall.sh` install DankMaterialShell as the
login shell rendered by bento: build + bundle Bento.app, GENERATE the macOS
wrapper QML (`shell-macos.qml`, `MacWallpaperBridge.qml`) into the DMS
checkout (they are build products - DMS's tracked tree stays pristine),
install the CLI shims and the `dev.bento` launch agent. The shims cover
what the shell actually execs on macOS: `dms` (restart/ipc/clipboard/dl),
`gsettings` (color-scheme -> system appearance), `cava` (injects the
audio-tap fifo input), and `niri` (DMS's niri path shells out to `niri
validate` / `niri msg -j outputs` / `niri msg output ...`; the shim runs
nigiri's config parser for validate and forwards msg requests over nigiri's
niri-IPC socket, unwrapping replies like `niri msg -j` - display settings
come back as nigiri's honest Err, macOS owns those). The scripts are
versioned HERE because DMS itself must not be modified; they default to the
sibling `../DankMaterialShell` checkout (override with `DMS_DIR`). The
wrapper embeds a copy of upstream `shell.qml`'s body (QML has no include),
so install.sh carries a hash guard that warns loudly when upstream
`shell.qml` changes and the copy needs review.

## Development

```sh
swift build && .build/debug/dms-darwin selftest
```
