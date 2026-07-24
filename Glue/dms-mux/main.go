// dms-mux: fronts $DMS_SOCKET and merges the Go DMS daemon (portable caps:
// plugins/browser/theme.auto/wallpaper/sysupdate/location) with the Swift
// dms-darwin daemon (macOS-native: brightness/gamma/bluetooth/freedesktop).
// DMS connects to the mux; the mux dials both, routes each request to the
// backend that serves its service, fans events from both to DMS, and MERGES
// the two `server` handshake events (each daemon sends one after `subscribe`)
// into a growing capability union so DMS sees every capability. Both daemons
// stay unchanged.
package main

import (
	"bufio"
	"encoding/json"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// resolveGo turns a glob (e.g. .../danklinux-*.sock) into a live socket path.
func resolveGo(pat string) string {
	if !strings.ContainsAny(pat, "*?") {
		return pat
	}
	matches, _ := filepath.Glob(pat)
	for _, m := range matches {
		if c, err := net.Dial("unix", m); err == nil {
			c.Close()
			return m
		}
	}
	if len(matches) > 0 {
		return matches[len(matches)-1]
	}
	return pat
}

// Method prefixes the Swift dms-darwin daemon serves on macOS (from
// Server.swift's route table). Everything else -> the Go daemon.
// clipboard.* is Swift-owned: the Go daemon's clipboard channel needs a
// Wayland ext-data-control device and never initializes on macOS, so the
// Swift daemon (NSPasteboard) is the only one that serves it.
// cups.* is Swift-owned too: the Go daemon's IPP client dials cupsd over TCP
// localhost:631, but macOS's cupsd is launchd-socket-activated on its domain
// socket and its TCP listener is only up while cupsd is awake, so the Go init
// hits "connection refused". The Swift channel drives the CUPS CLI, which uses
// the always-available domain socket.
// evdev.* (Caps Lock) is Swift-owned too: the Go daemon reads a Linux
// /dev/input device; the Swift channel reads CGEventSource on macOS.
// network.* (WiFi/Ethernet/VPN) is Swift-owned: the Go daemon's backend is
// NetworkManager/iwd D-Bus (Linux-only); the Swift channel uses CoreWLAN +
// SystemConfiguration + scutil.
var swiftPrefixes = []string{"brightness.", "wayland.gamma.", "bluetooth.", "freedesktop.", "clipboard.", "cups.", "evdev.", "network.", "loginctl."}

// Event `service` names the Swift daemon owns; the same-named event from the
// (hollow) Go daemon must be dropped so DMS sees only the real one.
var swiftEventServices = map[string]bool{
	"brightness": true, "gamma": true, "bluetooth": true, "freedesktop": true,
	"clipboard": true, "cups": true, "evdev": true,
	"network": true, "network.credentials": true, "loginctl": true,
}

func toSwift(method string) bool {
	for _, p := range swiftPrefixes {
		if strings.HasPrefix(method, p) {
			return true
		}
	}
	return false
}

func main() {
	listenPath := os.Getenv("DMS_SOCKET")
	if listenPath == "" {
		listenPath = "/tmp/dms-darwin.sock"
	}
	goPath := os.Getenv("DMS_GO_SOCKET")
	swiftPath := os.Getenv("DMS_SWIFT_SOCKET")
	if goPath == "" || swiftPath == "" {
		log.Fatal("set DMS_GO_SOCKET and DMS_SWIFT_SOCKET")
	}
	os.Remove(listenPath)
	ln, err := net.Listen("unix", listenPath)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("dms-mux on %s (go=%s swift=%s)", listenPath, goPath, swiftPath)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go handle(c, goPath, swiftPath)
	}
}

type conn struct {
	dms      net.Conn
	wmu      sync.Mutex
	capMu    sync.Mutex
	capSet   map[string]bool
	capOrder []string
	api      int
}

func (c *conn) writeDMS(b []byte) {
	c.wmu.Lock()
	c.dms.Write(b)
	c.wmu.Unlock()
}

// Rewrite a `server` handshake event to carry the accumulated capability union
// and max apiVersion; pass every other line through unchanged.
func (c *conn) relay(line []byte, isSwift bool) {
	var msg map[string]any
	if json.Unmarshal(line, &msg) == nil {
		if res, ok := msg["result"].(map[string]any); ok {
			svc, _ := res["service"].(string)
			// Ownership filter: a service's events come only from its owner.
			// (Responses to routed requests carry no "service" and pass.)
			if svc != "" && svc != "server" {
				if swiftEventServices[svc] != isSwift {
					return
				}
			}
			if res["service"] == "server" {
				if data, ok := res["data"].(map[string]any); ok {
					c.capMu.Lock()
					if caps, ok := data["capabilities"].([]any); ok {
						for _, cv := range caps {
							if cs, ok := cv.(string); ok && !c.capSet[cs] {
								c.capSet[cs] = true
								c.capOrder = append(c.capOrder, cs)
							}
						}
					}
					if av, ok := data["apiVersion"].(float64); ok && int(av) > c.api {
						c.api = int(av)
					}
					data["capabilities"] = c.capOrder
					data["apiVersion"] = c.api
					c.capMu.Unlock()
					if out, err := json.Marshal(msg); err == nil {
						c.writeDMS(append(out, '\n'))
						return
					}
				}
			}
		}
	}
	c.writeDMS(line)
}

func handle(dms net.Conn, goPath, swiftPath string) {
	defer dms.Close()
	goc, err := net.Dial("unix", resolveGo(goPath))
	if err != nil {
		return
	}
	defer goc.Close()
	swc, err := net.Dial("unix", swiftPath)
	if err != nil {
		return
	}
	defer swc.Close()

	c := &conn{dms: dms, capSet: map[string]bool{}}

	pump := func(bc net.Conn, isSwift bool) {
		r := bufio.NewReaderSize(bc, 1<<20)
		for {
			line, err := r.ReadBytes('\n')
			if len(line) > 0 {
				c.relay(line, isSwift)
			}
			if err != nil {
				return
			}
		}
	}
	go pump(goc, false)
	go pump(swc, true)

	dmsR := bufio.NewReaderSize(dms, 1<<20)
	for {
		line, err := dmsR.ReadBytes('\n')
		if len(line) > 0 {
			var m struct {
				Method string `json:"method"`
			}
			json.Unmarshal(line, &m)
			switch {
			case m.Method == "subscribe":
				goc.Write(line)
				swc.Write(line)
			case toSwift(m.Method):
				swc.Write(line)
			default:
				goc.Write(line)
			}
		}
		if err != nil {
			return
		}
	}
}
