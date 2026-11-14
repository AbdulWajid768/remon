<p align="center"><img src="docs/assets/icon-256.png" alt="Remon" width="128" height="128"></p>

# Remon

A native macOS network monitor, written in Swift 6 and SwiftUI.

Remon shows live per-app bandwidth, every open connection with its hostname, country and network
owner, a world map of destinations, per-minute usage history, a searchable connection log, speed
tests, data-plan tracking and alerts. It also includes an iStat-style **System** view — CPU per
core, GPU, memory, temperatures, fans, power, battery and disk — and **blocking** of domains and
servers.

It needs no system extension, kernel extension or third-party package. Blocking asks for an
administrator password through the standard macOS prompt.

## Requirements

Deployment target is macOS 15.0; developed and tested on macOS 26. Building needs Xcode 26 or later.

## Build and run

```bash
open Remon.xcodeproj        # then ⌘R
```

```bash
xcodebuild -project Remon.xcodeproj -scheme Remon -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Remon.app
```

```bash
xcodebuild -project Remon.xcodeproj -scheme Remon -derivedDataPath build/DerivedData test
```

The app is ad-hoc signed ("Sign to Run Locally") with Hardened Runtime, and the **App Sandbox is
off** — see [Limitations](#limitations). If `xcodebuild` fails with "failed to load a required
plug-in", run `xcodebuild -runFirstLaunch` once.

## Features

**Traffic**

- **Apps** — sortable table of live download/upload, sparkline, session totals and connection count.
  The inspector adds a 2-minute chart, today's usage, PIDs, path, open connections and a 7-day chart.
- **Connections** — Active / Listening / All, with protocol, service name, hostname, flag, city,
  TCP state, per-socket rates and RTT. Closed sockets stay dimmed for 8 s.
- **Overview** — live rates and peaks, today and session totals, a 5-minute mirrored throughput
  chart, top apps, network status and interfaces, destinations by country, and an **Unattributed**
  tile (kernel total minus the per-app sum).
- **History** — hourly, 7-day and 30-day stacked bars with hover, summary tiles and top apps.
- **Connection log** — every connection written to SQLite when it closes; searchable over the last
  hour, day, week or all time; exportable to CSV.
- **Map** — located destinations plotted with MapKit on a 3D globe or flat map, bubbles sized by
  data, geodesic arcs from this Mac's public location, and a side panel that flies the camera.
- **Speed test** — Apple's built-in `networkQuality`, reporting download, upload, responsiveness
  (RPM) and idle latency, with a gauge, history chart and saved results.

**System** (⌘2, sampled every 2 s off the main thread)

- **CPU** — total load, per-core bars labelled E/P, load averages.
- **GPU** — utilisation and memory in use, from the `IOAccelerator` registry entry.
- **Memory** — Activity Monitor–style breakdown, swap and memory pressure.
- **Temperatures** — ~70 die, battery and NAND sensors via `IOHIDEventSystemClient`, grouped by
  CPU / GPU / battery / storage. GPU temperature comes from SMC `Tg*` keys.
- **Fans, power, battery and disk** — RPM and range, watts, charge and health, free space and live
  read/write throughput.

These also feed the menu bar panel, the floating monitor, a CPU-temperature alert rule and a
**Get System Status** Shortcuts action.

**Blocking** (Rules), applied system-wide

- **Domains** go into a managed block in `/etc/hosts`, followed by a DNS cache flush. The original
  is backed up to `/etc/hosts.remon-backup` and restored byte for byte on unblock.
- **Servers** become `pf` rules in Remon's own `com.apple/remon` anchor — the stock `/etc/pf.conf`
  already evaluates `com.apple/*`, so no system file is edited. Existing connections are killed.
- **Quick Blocks** for macOS Software Update, Google Chrome updates and Microsoft AutoUpdate.
- Right-click any connection to block or unblock its server.

**Alerts** — total rate, app rate, daily budget, first-time app, unusual usage (3× an app's daily
average and at least 50 MB), CPU temperature, connectivity changes, public-IP and VPN changes, and
a daily digest. Each rule has a sustain duration and cooldown; delivery is through
`UNUserNotificationCenter`, and clicking a notification opens the relevant app.

**Elsewhere**

- **Menu bar** — a live mirrored mini-graph and stacked rates in four styles, with a popover showing
  a 60-second chart, today's totals and the top 5 apps.
- **Data plan** — monthly limit, reset day, usage ring, projected end-of-cycle total, and alerts at
  80% and 100%.
- **Search** — `app:` `host:` `ip:` `port:` `proto:` `country:` `state:` `iface:` `pid:` `cat:`
  filters, quoted values, `-negation` and live suggestions.
- **Quick Open (⌘K)** — keyboard-driven, Spotlight-style.
- **App Intents** — throughput, today's usage, busiest app, pause/resume, run a speed test, system
  status.
- **Global shortcut ⌃⌥⌘R** via the Carbon hotkey API, so no Accessibility permission is needed.
- **Export** — CSV and JSON for connections and app usage; CSV for history.
- **Palette** — every hue comes from `Palette` ([Palette.swift](Remon/Views/Components/Palette.swift));
  no view reaches for `.red`, `.blue` or `.green`. Each token is one hue at mid chroma: a deep jewel
  tone in light mode, the dusty pastel of that hue in dark. Five colour themes recolour every chart,
  the menu bar graph and the gauges live.

## How it works

| What | How |
|---|---|
| Per-process and per-socket bytes, TCP state, RTT and interface, for **all** processes including root daemons, without root | `/usr/bin/nettop -L 0 -x -n` streamed through a **pseudo-terminal** and parsed incrementally ([NettopParser.swift](Remon/Core/NettopParser.swift), [TrafficSource.swift](Remon/Core/TrafficSource.swift)) |
| Whole-machine throughput, per interface | Exact 64-bit counters from the interface MIB, `sysctl net.link.generic.ifdata` ([InterfaceCounters.swift](Remon/Core/InterfaceCounters.swift)) |
| Connectivity, interface type, expensive / Low Data Mode | `NWPathMonitor` |
| PID → app name, bundle, icon; helpers folded into their parent `.app` | `proc_pidpath`, `Bundle`, `NSWorkspace` |
| Reverse DNS | `getnameinfo(NI_NAMEREQD)`, cached |
| Country, city, ASN and organisation | `https://ipwho.is` (opt-out), rate-limited, cached in SQLite for 30 days. Private, link-local, CGNAT, loopback and multicast addresses are classified locally and never sent |
| History | SQLite at `~/Library/Application Support/Remon/history.sqlite` — per-app and total bytes per minute, a known-apps table and the geo cache |

## Updates

Remon updates itself with [Sparkle 2](https://sparkle-project.org). A released copy checks a signed
appcast once a day and installs a new build only if the download carries a valid EdDSA signature
from Remon's release key *and* is signed by the same Apple Developer ID as the installed copy. The
check is a plain HTTPS GET; no system profile is sent. Local builds have an empty `SUPublicEDKey`,
so the updater never starts.

Cut a release with `scripts/release.sh <version> [--publish]` — archive, Developer ID sign,
notarize, staple, zip, sign for Sparkle, update the appcast.
[docs/RELEASING.md](docs/RELEASING.md) covers the one-time setup.

## Testing

```bash
xcodebuild -project Remon.xcodeproj -scheme Remon -derivedDataPath build/DerivedData test
```

36 unit tests (Swift Testing) cover the pure layers: nettop parsing, the query language, address
classification, category heuristics, byte formatting, export encoding, SQLite round-trips,
billing-cycle maths, code-signature classification and the generated `pf` and hosts rules.

`scripts/e2e/RemonE2E.swift` drives the running app through the macOS Accessibility API — pressing
buttons, selecting rows, typing real keystrokes, using menus and the menu bar item, and checking the
screen after each step. All 82 checks pass.

```bash
swiftc -O -o build/remon-e2e scripts/e2e/RemonE2E.swift
build/remon-e2e                                     # all scenarios (Remon must be running)
build/remon-e2e connections menubar blocking        # or pick some
```

Keystrokes are posted only to Remon's process and only while it is frontmost, the blocking scenario
cancels the administrator prompt rather than entering a password, and exported test files are
deleted afterwards. The terminal running it needs Accessibility permission.

[docs/VERIFICATION.md](docs/VERIFICATION.md) records what was verified on the development machine,
what the end-to-end pass found, and what remains unverified.

### Launch arguments

Any `UserDefaults` key can be set on the command line. These are read once at launch and never
written back, so a demo run leaves real preferences alone.

| Argument | Effect |
|---|---|
| `-initialSection <name>` | Open on a section: overview, system, apps, connections, map, history, log, speed test, alerts or rules |
| `-skipOnboarding YES` / `-showOnboarding YES` | Suppress or force the welcome sheet |
| `-selectTop YES` | Auto-select the top app/connection so the inspector is populated |
| `-sidebarCollapsed YES` / `NO` | Force the sidebar hidden or shown, rather than restoring the last state |
| `-quickOpen YES` / `-openSettings YES` / `-previewMenuPanel YES` | Open Quick Open, Settings or the menu bar panel in a window |
| `-redactIdentity YES` | Replace this Mac's public IP, network owner, place and Wi-Fi name with documentation placeholders |
| `-appearance Light` | Override the appearance for one launch |

## Not implemented

| Capability | Why |
|---|---|
| **Per-app blocking** (block an app entirely, Little Snitch-style). Remon blocks domains and servers for all apps instead. | Needs an `NEFilterDataProvider` **system extension**, which requires a Developer ID certificate, the Network Extension entitlement from Apple, notarization and user approval — none available to an ad-hoc-signed build. `ConnectionPolicyEnforcer` is the seam for adding it. |
| Per-app data caps / metered-network blocking | Needs the same Network Extension. |
| Notification Center **widgets** | A WidgetKit extension needs an App Group, whose container ID needs a real Team ID. The App Intents provide the same data to Shortcuts meanwhile. |

## Limitations

- **Not sandboxed, not App Store–eligible.** Spawning `nettop` and reading other processes' paths
  isn't possible in the App Sandbox — the same reason iStat Menus and Little Snitch ship outside it.
  Distribution would be Developer ID plus notarization.
- **`nettop`'s CSV output is not a stable API.** The parser maps columns by header name and
  tolerates reordering; failures surface as a banner while interface-level monitoring keeps running.
- **Per-app numbers lag by one sample interval** — a frame is complete only when the next sample's
  header arrives. Whole-machine numbers have no lag.
- **"Unattributed" traffic is real:** kernel and system traffic, sockets that opened and closed
  between samples, and protocol overhead.
- **Rate edge cases.** The first sample of a newly seen connection counts all bytes since it opened.
  A PID that disappears and returns within 5 minutes is reconciled; after that its first sample
  counts the full cumulative total.
- **Geolocation uses a third-party free service** (ipwho.is) and sends public IPs to it. Disclosed
  in onboarding, switchable off, and cached.
- **Destination categories are heuristics** from PTR names and ASN owners, not a curated database.
- **Domain blocks** cover the exact names listed, so apps using DNS-over-HTTPS or hard-coded IPs can
  bypass them. **Server blocks** are cleared by a restart, since macOS loads only its own `pf`
  anchors at boot; the Rules screen flags this and re-applies with one click. To undo manually:
  `sudo pfctl -a com.apple/remon -F all`, then restore `/etc/hosts.remon-backup`.
- **Temperature sensors** use IOKit functions that exist but aren't in the public headers, resolved
  at runtime; if a future macOS removes them the sensor list comes back empty. SMC keys differ
  between Mac models — a Mac without fans hides the Fans card.
- **Speed tests use real bandwidth,** typically tens to hundreds of MB per run.
- **Wi-Fi SSID** shows only if macOS has granted Location access; signal, channel and rate don't
  need it.
- **Anomaly detection** needs at least three previous days of history for an app.
- **Up to one minute of history can be lost** on SIGKILL or a crash. Normal quits flush.
- **Pause** freezes the Apps and Connections tables; charts, totals and history keep recording.

## Project layout

```
Remon/
  App/          Scenes (main window, MenuBarExtra, Settings), AppDelegate, menu commands
  Core/         Data layer — no SwiftUI except Classification colours
                nettop parser and pty source, interface counters, NWPathMonitor wrapper,
                PID/hostname/geo resolvers, SQLite history, destination classification,
                code signatures, speed test, network environment, billing and anomaly maths,
                global hotkey, system metrics and SMC, block-rule enforcement, query language,
                formatting, Sparkle controller
  Store/        Observable state: MonitorStore, SystemMonitor, AlertCenter, Preferences, export
  Intents/      App Intents and App Shortcuts
  Views/        SwiftUI sections, plus Components (design system and Palette)
  Resources/    Asset catalog: app icon and accent colour
RemonTests/     Swift Testing suite
Config/         Info.plist with the Sparkle feed URL and public key
docs/           SPEC.md, RESEARCH.md, RELEASING.md, VERIFICATION.md, assets/, screenshots/
scripts/        release.sh, sparkle-keys.sh, appcast.py, make-icon.swift, screenshot tooling, e2e/
```

## Documents

- [docs/SPEC.md](docs/SPEC.md) — the feature spec, split into Core and Premium polish.
- [docs/RESEARCH.md](docs/RESEARCH.md) — competitive research (Little Snitch, LuLu, Radio Silence,
  TripMode, iStat Menus and others).
- [docs/RELEASING.md](docs/RELEASING.md) — cutting a signed, notarized release and how the updater
  reaches users.
- [docs/VERIFICATION.md](docs/VERIFICATION.md) — what was verified on the development machine, and
  what was not.
