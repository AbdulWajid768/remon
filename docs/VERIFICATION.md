# Verification log

What was checked on this Mac (macOS 26.0.1, Apple Silicon M4 Pro) while Remon was built, and what
was not. Kept out of the README because it is a development record rather than documentation, but
kept because "not verified" is as useful as "verified".

---

## Builds and tests

- Debug and Release builds succeed with **zero compiler warnings** in Swift 6 language mode
  (strict concurrency).
- The unit suite grew with the app: 18 tests at v1.0, 26 at v1.1, 33 at v1.2, 36 now. It covers
  nettop parsing (IPv6, QUIC, column reordering), the query language, address classification,
  category heuristics, helper grouping, byte formatting, CSV/JSON export encoding, SQLite
  round-trips, live interface counters, billing-cycle maths, anomaly thresholds, `networkQuality`
  JSON parsing, code-signature classification, and the generated `pf` and hosts rules.

## Found and fixed during verification

| Problem | Fix |
|---|---|
| `nettop` buffers output to a pipe, so samples arrived in multi-second bursts | Run it through a pseudo-terminal |
| `nettop` busy-looped at ~140% CPU when stdin was `/dev/null` | Give it the pty as stdin |
| `getifaddrs` / `NET_RT_IFLIST2` counters are rounded to 1 KiB for unprivileged apps | Switched to the exact interface MIB |
| Charts animating every second cost 20–45% CPU | Animation is opt-in. Idle CPU is now ~2–3% on most screens, 6–8% on the live Overview (Release, `top`); `nettop` itself ~0% |
| The app didn't exit on SIGTERM, and history was lost on any quit path because main-actor tasks don't run during `terminateLater` | The flush is synchronous |
| Orphaned `nettop` children survived a force-kill | They are reaped at launch |

## Found by the end-to-end pass

| Bug | Fix |
|---|---|
| **Battery health showed 93%; macOS says 99%.** Remon divided the gauge's raw capacity by design capacity, while macOS shows powerd's normalised "Maximum Capacity". | Read macOS's own figure (`system_profiler SPPowerDataType -json`, cached for 10 min). The raw mAh figure stays as an explained secondary line. A unit test compares against System Information on the host. |
| **App crash** (`NSInternalInconsistencyException`, "too many Update Constraints passes") after moving the inspector onto the split view. | Moved the single shared inspector onto the detail column. |
| **Inspector missing after switching sections** while the toggle said it was shown. Each section had its own `.inspector`. | One inspector for the detail column; its content follows the section. |
| **⌘F didn't focus search**, which the spec promised. | Added a Find command bound to `.searchFocused`. |
| **No window on relaunch** after the main window had been closed; a pending onboarding sheet could never appear. | Window restoration disabled for the main window; clicking the Dock icon reopens it. |
| **Switches couldn't be operated by VoiceOver / Switch Control.** Label-hidden switches in grouped forms exposed no `AXPress` action on macOS 26. | `AccessibleSwitch`, with an explicit accessibility action and labels such as "Block macOS Software Update". |
| **Menu bar panel ignored Escape.** The window-style MenuBarExtra never becomes key. Closing its window directly then made the next click a no-op. | A local key monitor while the panel is visible; it dismisses via the status-bar button so MenuBarExtra's state stays in sync. |
| **VoiceOver read raw icon names** ("pip", "gearshape", "Power"), stat tiles with empty values, a badge number instead of the sidebar row name, and a dozen date ranges for each mini chart. | Spoken labels for the icon buttons. Tiles become single elements with values. Badged rows are named. Charts read as one summary. |
| **An extra password prompt** when a cancelled block was switched back off. | Applying is skipped when the system already matches the rules. |
| **Sidebar and inspector cut off** in Apps and Connections. With the inspector open the content was 1,316 pt wide in a 1,200 pt window, and the sidebar was fully off-screen at 900 pt. The tables' column minimums didn't fit, and the detail column's effective minimum was ~780 pt. | Tables show only the columns that fit at their ideal widths, dropping the least important first. The detail `minWidth` is now 340 pt (effective ~560 pt). The window minimum rises to 1,100 pt while the inspector is open. |
| **Table columns hidden under the inspector.** A Table lays columns out at their ideal widths and scrolls sideways instead of shrinking them. | Column sets are chosen from ideal widths, and a new column set gets a fresh table. |
| **Uneven rows and clipped addresses** in Connections and Log, depending on whether the hostname had resolved. | Every row has two lines: hostname over address, or address over network owner. |
| **The app launched showing only the Menu Bar Preview window.** Once `-previewMenuPanel YES` had opened that window, macOS restored it on every later launch — and because the main window's own restoration is deliberately disabled, the app came back with the preview and nothing else. The preview `Window` scene had `.defaultLaunchBehavior(.suppressed)` but, unlike the floating monitor beside it, no `.restorationBehavior(.disabled)`. | Added `.restorationBehavior(.disabled)` to the preview window. |
| **Visual inconsistencies:** rate charts labelled "50 KB" instead of "50 KB/s"; truncated time labels; stat tiles of different heights; legends in three different places; CPU/GPU blue/purple in one chart and orange/pink in the next; a yellow status dot in the sidebar but green elsewhere. | One shared `ChartLegend` in each card's title row; consistent tile heights; sheet titles added to the alert and block editors. Colour is now centralised in `Palette`. |

## Measured

- **System view on this M4 Pro:** CPU per core with load landing on the E-cores as expected (CPUs
  0–3 are efficiency cores, checked against the device tree); GPU utilisation and memory; CPU ~40 °C
  and GPU ~46 °C; both fans "Off" at idle (range 2317–7826 rpm); 5 W system power; battery at 20%,
  66 cycles. Remon uses ~4–5% CPU with the System view open (Release, `top`).
- **End-to-end:** all 82 accessibility-driven checks pass. Memory stayed between roughly 200 and
  470 MB across every scenario.
- **Blocking:** generated rules pass `pfctl -n` (parse-only, unit-tested). The hosts-file script was
  run for real against a scratch file — block, replace, unblock restores the original byte for byte.
  Domain and IP input is strictly validated and injection attempts are rejected in tests.
- **Map:** confirmed by logging MapKit's camera that the automatic re-framing is gone, and that the
  flat map's ~137° zoom-out limit is a MapKit property rather than a bug in Remon.
- **Lifecycle:** ⌘Q and SIGTERM both flush history and leave no `nettop` behind. After SIGKILL the
  orphan is cleaned up on next launch.
- A real `networkQuality -c` run returned exactly the fields the parser reads: `dl_throughput`,
  `ul_throughput`, `responsiveness`, `base_rtt`, `interface_name`.

## Known open issue: one unexplained memory spike

During the first exploratory session (Debug build, ~30 minutes), Remon's footprint reached **107 GB**:
hundreds of ~125 MB large allocations, mostly swapped out. That session involved heavy, repeated
accessibility-tree crawls by `System Events`, which force SwiftUI to build accessibility trees for
2,000-row tables and charts. It has **not recurred** in four complete end-to-end runs since, each
tracking memory after every scenario (all stayed between ~190 and 470 MB). Normal navigation, the
onboarding sheet and long idle periods stay flat. The cause was not pinned down, so this is recorded
as an open issue rather than a fix.

## Not verified

- **Applying a block to this Mac.** That needs the administrator password at the macOS prompt, and
  this machine has no passwordless `sudo`. The first time you toggle a block, check the status card
  and test it (`curl -I https://swscan.apple.com` should fail).
- **Notification delivery.** The permission prompt was never answered, so no banner was confirmed.
  Alerts were confirmed firing into the in-app log, and the sidebar badge showed a "new app" alert.
- **Clicking the real status item** to open the popover. Its content was rendered via
  `-previewMenuPanel`, and the status item itself was captured in the menu bar.
- **Shortcuts actions** appearing in the Shortcuts app, and notification click-through.
- **The global hotkey** (⌃⌥⌘R).
- **A full in-app speed test** — only the `networkQuality` CLI run above.
- **VPN and IP-change alerts**, because no VPN was toggled.
- **Launch at login.** `SMAppService` registration may fail for an app run from DerivedData; the UI
  surfaces the error if so.
- **Running on macOS 15.** The deployment target is 15.0, but the app has only been run on macOS 26.
