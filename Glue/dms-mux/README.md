# dms-mux

Fronts `$DMS_SOCKET` and merges the two DMS daemons on macOS:

- the **Go daemon** (`dms-serve`, built from DankMaterialShell/core + darwin
  stubs) — portable capabilities: plugins, browser, theme.auto, wallpaper,
  location, sysupdate.
- the **Swift daemon** (`dms-darwin`) — macOS-native: brightness (DisplayServices),
  gamma (NightShift), bluetooth (IOBluetooth), freedesktop.

DMS connects to the mux; it dials both, merges their `server` handshake events
into a capability union (apiVersion 28), routes each request to the owning
backend by method prefix, and filters events so each service's events come only
from its owner. Both daemons stay unchanged. Built and wired by
`dms-darwin/Glue/install.sh`.
