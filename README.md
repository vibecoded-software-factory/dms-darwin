# dms-darwin

**The macOS half of [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell).**
A native daemon that speaks DMS's own daemon protocol, plus the glue that
assembles an unmodified DMS into a working macOS desktop.

DMS is a Linux shell. Its portable half is Go and runs on macOS unchanged; the
rest of it talks to NetworkManager, BlueZ, PipeWire, logind and D-Bus. This repo
supplies those capabilities from CoreWLAN, IOBluetooth, CoreAudio and friends,
behind the exact same wire protocol — so the shell never learns it is not on
Linux.

## The stack

Four pieces, three of them ours:

| | | |
|---|---|---|
| [nigiri](https://github.com/vibecoded-software-factory/nigiri) | ours | Scrollable-tiling window manager. Speaks niri's IPC. |
| [bento-box](https://github.com/vibecoded-software-factory/bento-box) | ours | macOS port of quickshell — the QML runtime that renders the shell. |
| **dms-darwin** | ours | This repo: the native daemon + all the glue. |
| [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) | **third-party** | The shell itself. **Read-only — never patched.** |

> [!IMPORTANT]
> The DankMaterialShell checkout is never written to. Not a patch, not a
> generated file. Our QML lives in `Glue/qml/` and reaches bento through an
> assembled staging root (see [Staging root](#staging-root)). A `git status` in
> that checkout must come back empty.

## Requirements

- **macOS 13+**, Xcode Command Line Tools (`xcode-select --install`)
- **Homebrew**, and from it: `cmake`, `ninja`, `qt`, `go`
- The four repos checked out **as siblings** in one directory — every script
  defaults to that layout and can be overridden (`DMS_DIR`, `BENTO_REPO`).

## Install

Order matters. Each step assumes the previous one ran.

```sh
# 1. The compositor. Grant Accessibility when macOS asks.
cd nigiri        && ./Scripts/install.sh

# 2. This daemon (agent dev.dms, socket /tmp/dms-darwin.sock).
cd ../dms-darwin && ./Scripts/install.sh

# 3. Everything else: the staging root, the CLI shims, the Go daemon,
#    dgop/dsearch/dcal, the daemon mux - and bento itself, which this
#    delegates to bento-box/Scripts/install.sh.
./Glue/install.sh
```

Step 3 is the one to re-run after almost any change; it is idempotent by
design. It does **not** build bento itself — that belongs to bento-box's own
installer, which it invokes with the right environment.

`Glue/uninstall.sh` tears down the shell side (agent, bundle, staging root).

### Permissions

macOS will ask, and the features degrade rather than break if you decline:

- **Accessibility** — nigiri, to move windows at all. Not optional.
- **Screen Recording** — window previews in the overview, and the audio tap.
- **Bluetooth**, **Microphone**, **Location** — the bar's Bluetooth status, the
  audio visualiser, and WiFi SSID names (macOS gates SSIDs behind Location).

Grants are keyed to a **code signature**, which is why everything ships as a
signed `.app` with a stable self-signed certificate rather than an ad-hoc one.
An ad-hoc signature mints a new identity per build and silently drops every
grant you granted.

## How the pieces talk

```
                  ┌──────────────────────────────────────┐
                  │ bento (dev.bento) — the QML runtime  │
                  │   DankMaterialShell, unmodified      │
                  └──┬────────────┬──────────────┬───────┘
      reserve-zone   │            │              │ exec()
      (panel struts) │            │              ▼
                     ▼            ▼        ~/.local/bin/{dms,niri,gsettings,
            /tmp/nigiri-msg.sock  │         cava,notify-send,getent,...}
                     │            │
                     ▼            ▼
                  nigiri     /tmp/dms-darwin.sock  ← dms-mux
                                   ├── dms-darwin (Swift): brightness, gamma,
                                   │   bluetooth, clipboard, cups, evdev,
                                   │   network, loginctl, freedesktop
                                   └── dms-serve (Go): plugins, browser,
                                       theme.auto, wallpaper, location, sysupdate
```

**Compositor IPC** — nigiri serves niri's JSON line protocol and exports
`NIRI_SOCKET` session-wide. Three clients: the shell's own `NiriService`, bento
(to reserve panel space, macOS having no layer shell), and a `niri` CLI shim.

**Daemon protocol** — newline-delimited JSON over `$DMS_SOCKET`:
`{"id":N,"method":"svc.name","params":{}}`, plus a `subscribe` channel that
streams events. See `Sources/dms-darwin/Protocol.swift`.

**`dms-mux`** is the piece that makes two daemons look like one. DMS connects to
a single socket; the mux dials both backends, routes each request by method
prefix, filters events to their owning daemon, and **merges the two `server`
handshakes into one capability union** — so the shell sees a single daemon that
can do everything. Neither daemon knows it exists (`Glue/dms-mux/`).

**Shims** are the fourth channel. DMS shells out to Linux tools; `Glue/install.sh`
generates stand-ins on `PATH` that translate — `gsettings` → macOS appearance,
`cava` → the audio-tap fifo, `xdg-open` → `open`, `notify-send`, `getent`,
`niri`, and a `dms` CLI that dispatches the rest to the real Go binary.

### Staging root

bento roots `import qs.*` and every relative `source:` at the **directory of the
`-p` file** (`core/rootwrapper.cpp`). So our entry point cannot simply live
outside DMS and point back — its imports would resolve next to itself.

`Glue/install.sh` therefore assembles `~/.local/share/dms-darwin/shell/`: one
symlink per top-level entry of the DMS checkout, plus our real
`shell-macos.qml` and `MacWallpaperBridge.qml` from `Glue/qml/`. That directory
is a valid shell root, and DMS is only ever read through it.

## The daemon

```sh
dms-darwin serve       # what the launchd agent runs
dms-darwin selftest    # pure-logic checks, no socket needed
dms-darwin lock        # native lock screen
dms-darwin audio-tap <fifo>
dms-darwin color-pick  # NSColorSampler, for the shell's eyedropper
```

Services live one to a file under `Sources/dms-darwin/`. Logs go to
`/tmp/dms-darwin.log`; the mux logs to `/tmp/dms-mux.log`.

## Development

```sh
swift build
.build/debug/dms-darwin selftest
./Scripts/install.sh
```

The selftest covers what is pure — protocol parsing and serialisation, the
brightness curve — so it needs no socket and no permissions. Everything else
talks to real hardware and is verified live.

## License

[MIT](LICENSE) © 2026 vibecoded-software-factory
