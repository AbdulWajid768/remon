# Remon — Feature Specification

Remon is a native macOS network monitor. It answers "what on my Mac is talking to the network, to whom, and how much" at a glance, without asking the user to approve a system extension first.

This spec is derived from the competitive research in [RESEARCH.md](RESEARCH.md). The research found that the market splits into **Network Extension firewalls** (Little Snitch, LuLu, Radio Silence, TripMode), which can attribute and block but are hard to set up and break on macOS updates, and **stat readers** (iStat Menus, Bandwidth+, NetWorker), which are easy but shallow. Remon's position is **"deep visibility with zero setup"**: monitor first, with no prompts, and keep enforcement (blocking) behind a clean, optional seam.

Status tags: **[Shipped]** is implemented in this build, **[Stub]** is implemented behind a protocol with a non-enforcing stub, and **[Future]** is not in this build.

---

## Part A — Core features (baseline every serious monitor must have)

### A1. Per-process / per-app bandwidth [Shipped]
- Live download and upload rate for every process that owns a socket, including root-owned system daemons, refreshed every 1 s (configurable to 1/2/5 s).
- Helper processes are grouped under their parent `.app` bundle (e.g. "Google Chrome Helper" → Google Chrome), and grouping can be switched off.
- Session totals per app, a connection count, and a 60-sample sparkline.
- App identity is resolved from the executable path (`proc_pidpath`) to the bundle's display name and icon. System and Apple processes are labeled as such.

### A2. Live connection list [Shipped]
- Every TCP, UDP and QUIC socket: owning app and process, PID, protocol, IP family, local and remote endpoints, TCP state, interface, live rate, bytes since open, and average RTT.
- Filters: **Active** (has a remote peer), **Listening/Bound**, and **All**.
- Closed connections linger for about 8 s, dimmed, so short-lived flows are still visible.

### A3. Remote host and geo resolution [Shipped]
- Reverse DNS (PTR) for every remote address, cached.
- Geolocation (country, region, city, ASN, organisation) for public addresses, cached on disk for 30 days and rate-limited. It is opt-out and disclosed during onboarding.
- Local addresses (RFC 1918, CGNAT, link-local, loopback, multicast, ULA) are classified on the Mac and never sent anywhere.

### A4. Protocol and port detail [Shipped]
- Protocol (TCP/UDP/QUIC), IPv4/IPv6, and a well-known service name for the port (HTTPS, DNS, APNs, mDNS, SSH, …), falling back to `getservbyport`.

### A5. System throughput and interfaces [Shipped]
- Whole-machine rates come from exact 64-bit kernel interface counters (`sysctl net.link.generic.ifdata`, the interface MIB). `getifaddrs` and `NET_RT_IFLIST2` round to 1 KiB for unprivileged processes, and `getifaddrs` also wraps at 4 GB.
- A per-interface breakdown (Wi-Fi, Ethernet, VPN/utun, Thunderbolt bridge) with each interface's addresses.
- Connectivity status from `NWPathMonitor`: satisfied or unsatisfied, interface type, and whether the network is expensive or constrained (Low Data Mode).
- "Unattributed" traffic: the kernel interface total minus the sum of per-app traffic. Showing it was a gap the research found.

### A6. Historical usage [Shipped]
- Every app's traffic and the machine total are stored per minute in a local SQLite database (`~/Library/Application Support/Remon/history.sqlite`).
- History view for Today (hourly), 7 days and 30 days (daily), with top apps for the selected range.
- Retention is configurable (30/90/365 days). History can be cleared.

### A7. Alerts on thresholds [Shipped]
- Rule types:
  - total rate above X for N seconds
  - any app or a specific app above X for N seconds
  - daily total above X
  - an app uses the network for the first time ever
- Per-rule cooldown so alerts don't fatigue the user.
- A first-run learning period seeds the "known apps" list silently instead of firing dozens of alerts.
- An in-app alert log is always kept. macOS notifications are optional.

### A8. Blocking / firewall rules [Shipped in v1.2 for domains and servers; per-app = Future]
- Block **domains** system-wide through a managed `/etc/hosts` block, and **servers** (IPs) through a `pf` anchor (`com.apple/remon`). Live connections to a blocked server are killed.
- Presets for macOS Software Update, Google Chrome updates and Microsoft AutoUpdate.
- Changes go through the standard macOS administrator prompt. The UI shows whether rules are active, pending, or need re-applying after a restart.
- Blocking an *app* outright needs an `NEFilterDataProvider` system extension (Developer ID, the Network Extension entitlement, user approval). That remains the extension point behind `ConnectionPolicyEnforcer`.

### A9. Robustness [Shipped]
- If `nettop` is unavailable or exits, the app shows a clear status, keeps interface-level monitoring running, and retries with backoff. This responds to the research finding that users hate tools that fail silently.

---

## Part B — Premium polish (what makes it feel like a paid, first-class Mac app)

### B1. Menu bar live graph [Shipped]
- A menu bar item draws a live mirrored mini-graph (download up, upload down), with optional stacked up/down rates in iStat style.
- Styles: Graph + Rates, Graph, Rates, Icon only. Monochrome template rendering by default so it matches the menu bar, with an optional colored mode.
- Clicking opens a popover panel:
  - live rates with numeric-transition animation
  - a 60-second chart
  - today's totals
  - the top 5 apps with icons
  - network status
  - Pause, Open Remon, Settings and Quit

### B2. Native SwiftUI design language [Shipped]
- A `NavigationSplitView` with sidebar badges, a toolbar live-rate pill, a native `Table` with sortable columns and context menus, and an `.inspector` side panel.
- Semantic colors throughout. SF Symbols with symbol effects. Card layout on the Overview.

### B3. Smooth animated charts [Shipped]
- Swift Charts with Catmull-Rom interpolation, gradient areas, and download/upload mirrored around zero.
- Animated sliding window, and hover selection showing a rule and a value callout.
- Stacked bar history charts with hover.

### B4. Dark mode [Shipped]
- Follows the system by default. Appearance override in Preferences: System, Light or Dark.

### B5. Spotlight-quality search and filtering [Shipped]
- Toolbar search with a small query language:
  - free text matches app, process, host, IP, port, service, country, city, organisation and category
  - all terms must match, and `-term` excludes
  - `key:value` filters (`app:`, `host:`, `port:`, `proto:`, `country:`, `state:`, `iface:`, `pid:`, `cat:`), with quoted values supported
  - live search suggestions
- **Quick Open (⌘K):** a Spotlight-style palette that jumps to any section, app or remote host with the keyboard.

### B6. Keyboard shortcuts [Shipped]
- ⌘1–⌘6 switch sections, ⌘K Quick Open, ⌘F search, ⇧⌘P pause/resume, ⌥⌘I toggle inspector, ⌘E export connections, ⇧⌘E export app usage, ⌘, Preferences, ⌘0 show main window.

### B7. Onboarding [Shipped]
- A three-page first-run sheet:
  1. What Remon does.
  2. Privacy choices, with reverse DNS and geolocation toggles and an honest disclosure of what leaves the Mac.
  3. Notifications permission, launch at login and menu bar options.
- Can be replayed from Preferences.

### B8. Notifications [Shipped]
- `UNUserNotificationCenter` alerts for the rules in A7. They appear even while the app is frontmost.

### B9. Export [Shipped]
- Connections, app usage and history export to CSV or JSON through a native save panel. Available from the File menu and the toolbar.

### B10. Apple-native Preferences window [Shipped]
- A `Settings` scene with General, Monitoring, Privacy, Notifications and Advanced tabs, using grouped forms.
- Settings include launch at login (`SMAppService`), Dock icon visibility, menu bar style, sample interval, bits vs. bytes, loopback inclusion, helper grouping, retention, and clear/reveal data.

### B11. Destination labeling [Shipped]
- Remote hosts are labeled heuristically from the PTR name and ASN organisation: Apple, Google, Microsoft, Amazon/AWS, Cloudflare, Akamai, Fastly, Meta, CDN, Analytics/Telemetry, Advertising, Software Update and Local network.
- The research identified this as a gap: users want context on what a connection *is*, not just a prompt about it.

### B12. App icon [Shipped]
- A generated, full-resolution macOS app icon set.

---

## Part C — Premium additions (v1.1)

| Feature | Status | Notes |
|---|---|---|
| C1. Code-signature provenance per app (Apple / App Store / Developer ID / Ad-hoc / Unsigned / Invalid, Team ID) | [Shipped] | Little Snitch–style trust signal; filter for unsigned apps |
| C2. World map of destinations with geodesic arcs from your location | [Shipped] | MapKit; uses coordinates from geo lookups |
| C3. Persistent, searchable connection log with export | [Shipped] | SQLite; same retention as history |
| C4. Speed / responsiveness test | [Shipped] | Apple `networkQuality`, history kept |
| C5. Public IP, ISP and VPN detection, with change alerts | [Shipped] | Behind the geo-lookup privacy toggle |
| C6. Monthly data plan with billing cycle, projection and alerts | [Shipped] | TripMode-style awareness without enforcement |
| C7. Anomaly alerts, connectivity alerts, daily digest, notification click-through | [Shipped] | Answers the "alert fatigue" complaint with fewer, more meaningful alerts |
| C8. Wi-Fi signal details | [Shipped] | CoreWLAN; SSID needs Location permission |
| C9. Floating always-on-top monitor | [Shipped] | ⌥⌘M |
| C10. Shortcuts / Siri actions | [Shipped] | App Intents, 5 actions |
| C11. Global hotkey | [Shipped] | ⌃⌥⌘R |
| C12. Color themes | [Shipped] | Five presets |
| C13. Per-app 7-day chart | [Shipped] | Apps inspector |
| C14. Widgets | [Future] | Needs an App Group, so a Developer ID team |

## Part D — v1.2

| Feature | Status | Notes |
|---|---|---|
| D1. System metrics: CPU per core (E/P), GPU, memory and pressure, temperatures, fans, power, battery, disk I/O | [Shipped] | Mach/IOKit; HID temperature sensors; read-only SMC |
| D2. System readout in the menu bar, menu panel and floating monitor; temperature alert; Shortcuts action | [Shipped] | |
| D3. Real blocking of domains (`/etc/hosts`) and servers (`pf` anchor `com.apple/remon`), with presets for macOS / Chrome / Microsoft updates | [Shipped] | Admin prompt; server rules re-apply after a restart |
| D4. Map: stable camera, globe mode with full zoom-out, Fit All | [Shipped] | Fixes the zoom-out bug |

## Out of scope for this build
- Packet capture or HTTP(S) inspection (the Charles/Proxyman domain). It needs a proxy, a root CA and user trust.
- Per-network profiles and data caps with enforcement (TripMode). These need the Network Extension from A8.
- Code-signature verification of the remote process (Little Snitch-style). The `SecCode` APIs could do this for the user's own processes, but it is deferred.
