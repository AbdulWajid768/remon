# Competitive Research: macOS Network Monitoring Apps

_Compiled 2026-10-31 for Remon, a native SwiftUI network monitor for macOS._

**How to read this:** claims come from the pages listed under [Sources](#sources). Anything marked **(general knowledge, unverified)** comes from prior knowledge and was not confirmed by a source read for this document. Prices are list prices at the time of reading and change often.

---

## 1. Landscape at a glance

| App | Category | Pricing | Kernel/OS hook | Blocks traffic? |
|---|---|---|---|---|
| Little Snitch 6 | Firewall + monitor | $59 one-time (upgrade from $39); family €115 | Network Extension (content filter + DNS proxy) | Yes, in and out |
| Little Snitch Mini | Monitor (block via IAP) | Free monitor; paid IAP for blocking and long history | Network Extension **(general knowledge, unverified)** | Paid tier only |
| LuLu (Objective-See) | Outbound firewall | Free, open source | System Extension + Network Filter | Yes, outbound only |
| Radio Silence | Silent outbound firewall | $9 one-time | Network Extension (approved in System Settings) | Yes, outbound only |
| TripMode | Data saver / per-app blocker | ~$14.99/yr App Store, lifetime option, or one-time from ~$15 direct; Setapp | Network Extension | Yes (allow-list) |
| iStat Menus 7 | System monitor (network module) | ~$11.99 ($9.99 upgrade); Setapp | None, reads OS stats | No |
| Murus / Vallum | pf GUI / app firewall | "Pro Bundle" (Murus Pro ~$35 per a hosting guide) | pf (Murus); socket-call hooks (Vallum) | Yes |
| Netiquette | Connection viewer | Free, open source | None **(general knowledge, unverified)** | No |
| Bandwidth+, NetWorker, NetPulse, etc. | Menu-bar speed/usage meters | Free to a few dollars | Mostly none; NetPulse uses an optional observe-only NE for per-app data | No |
| Network Radar | LAN scanner | ~€20-30 (often discounted) | None | No |
| Charles 5 / Proxyman | HTTP(S) debugging proxies | Charles $50; Proxyman free tier, $89+ paid | System proxy + trusted root CA (Proxyman also offers a VPN mode for mobile) | No (inspect/modify) |

The table splits into two technical classes:

1. **Network Extension (NE) filters.** These are Little Snitch, LuLu, Radio Silence, TripMode and NetPulse's per-app mode. They see every flow and can attribute it to a process and block it. The cost is a user-approved system extension, exposure to macOS networking bugs, and the chance of breaking the user's internet.
2. **Stat readers.** These are iStat Menus, Bandwidth+, NetWorker and Netiquette. They read interface counters or per-socket stats, need no approval, and can't break networking. They also can't block anything and have weaker per-process attribution.

---

## 2. App-by-app

### 2.1 Little Snitch 6 (Objective Development), including Network Monitor and Mini

**What it is:** The best-known host-based firewall for macOS. Version 6 shipped in May 2024 and needs macOS 14 or later. It has been kept current through 6.3 (macOS 26 Tahoe) and 6.5 (macOS 27). In April 2026 Objective Development also released a free Linux version built on eBPF.

**Pricing:** $59 for a single license, upgrades from $39, €115 for a family pack and from €239 for 5+ seats. The demo is fully functional for 3 hours per session and can be restarted.

**What it does well:**
- **Network Monitor.** It has an interactive traffic chart and hierarchical grouping by app, domain, server or country. Search and filters are good, and a map view shows where traffic goes. The v6 menu-bar "Control Center" shows recent activity and recently blocked connections.
- **Blocklists.** One-click subscriptions to lists like Peter Lowe's and URLhaus. These were brought over from Little Snitch Mini.
- **Built-in encrypted DNS.** DoH/DoT, and DoQ in some cases, with Quad9, Cloudflare, Google and dns0.eu. Heise found this easier than setting it up in System Settings.
- **Rule hygiene.** Rules can be sorted by last-used date or usage count, and an "Unused" filter helps clean up. Rules can be grouped and toggled together, and code-signing identifiers make app matching more reliable.
- **Profiles and silent modes.** Silent-allow and silent-deny modes, plus per-network profiles. MacPowerUsers users recommend starting in silent-allow mode to avoid being buried in prompts.
- **Polish.** Users consistently rate it above LuLu on UI and on depth of analysis (MacPowerUsers, Privacy Guides).

**What users complain about:**
- **Alert fatigue and "WebMD effect."** One MacPowerUsers user saw no value after Safari needed so many connections allowed. Another said they spent hours chasing benign CDN connections and compared the app to "WebMD." A third found it "just too much" and uninstalled it. A MacRumors user described lots of popups at first that taper off once rules are built.
- **Intimidating at first.** Users call it "quite intimidating" and say it "can be overwhelming."
- **macOS update breakage.** TidBITS says pre-6.5 versions "will break your Internet connection" on macOS 27, so users must update before the OS. On Sequoia 15.0 and 15.1, Apple's built-in firewall stopped NE firewalls from receiving any traffic data. Alerts and rules silently stopped working until macOS 15.2, and Objective Development's workaround was to turn off Apple's firewall. Little Snitch 6.1 also had a DNS-proxy bypass regression, fixed in 6.1.1.
- **Leaks the OS won't let it close.** Heise notes a remaining "TCP leak": handshake packets go out before Little Snitch can decide. Big Sur's ContentFilterExclusionList let roughly 50 Apple apps bypass NE filters until Apple removed it in 11.2.
- **Trust and price.** It is closed source and $59. Privacy Guides users raise vendor-sale risk and prefer FOSS.
- **History granularity.** In an older MacRumors thread, a user found the monitor's "flashing graphs" too coarse to read per-app numbers. Little Snitch Mini puts extended history (up to 12 months) behind its paid IAP.

**Extension:** Yes. It uses the Network Extension framework (Objective Development's own Sequoia posts confirm this) and also runs a DNS proxy.

### 2.2 LuLu (Objective-See / Patrick Wardle)

**What it is:** A free, open-source (GPL) outbound firewall. It needs macOS 10.15 or later; the current version is 4.5.x.

**Pricing:** Free. Development is funded by donations and Patreon **(general knowledge, unverified)**.

**What it does well:**
- **Informative alerts.** Each alert shows the process, destination, code-signing info, process ancestry and a VirusTotal lookup.
- **Flexible rule scope.** Rules can cover the whole process or a single endpoint. They can last forever, for the life of the process, or until a set expiry, and they accept regexes.
- **Lists and profiles.** Block and allow lists can come from local files or remote URLs. Profiles arrived in v4, and modes include passive and block-all.
- **Bundled monitor.** It ships with the Netiquette network monitor.
- **Value and trust.** It is free and open source and needs no registration, which Privacy Guides users value highly.

**What users complain about:**
- **Less polished and less capable than Little Snitch.** Privacy Guides users call it "far less featured" with weaker user control. It lacks multiple blocklists and secure DNS. One MacPowerUsers user was put off by the "monospace terminal aesthetic."
- **Alerts aren't really fewer.** One switcher from Little Snitch said the popup volume was about the same.
- **Network breakage, per open GitHub issues.** Issue #530, open since 2023, reports dropped SSH and IRC sessions and data corruption when LuLu is chained with another NE filter such as SentinelOne, Defender or Proxifier. Other open issues report DNS stalls (#920) and all new connections stalling when Spotlight's `mds` crashes (#929). There is also a roughly 60-second app freeze when pasting HTML (#919) and a 4.5.5 update that broke previously allowed SSH (#945).
- **macOS updates.** Users report "could not communicate with its system extension" on macOS 27 (#926) and instability on 27 betas (#895). Objective-See says Sequoia below 15.3 broke "many aspects of networking."
- **Platform limits, documented by Objective-See.** It can't see traffic that doesn't go through NE. Hostname rules only work for Network.framework and NSURLSession traffic, so Chrome only gets IP-based rules. It has no inbound filtering.

**Extension:** Yes. It needs both a System Extension and a Network Filter, which the user approves manually.

### 2.3 Radio Silence

**What it is:** A deliberately minimal outbound firewall with a connection monitor.

**Pricing:** $9 one-time, with a free trial and a 30-day money-back guarantee.

**What it does well:** No pop-ups and no menu-bar icon: it's "invisible and always active." The monitor shows connections live, and a misbehaving app can be blocked in one click. It also exposes helper processes, daemons and XPC services, and blocking an app also blocks its child processes. Macworld called it "perhaps the easiest firewall" and indispensable for under $10.

**What users complain about:** It has no inbound rules, no detailed traffic analysis and no intrusion detection. Reviewers say it suits blocking one or two apps, and power users should get Little Snitch. Its own install guide warns that macOS defaults the extension prompt to "Don't allow," so users can easily leave it disabled. I found little recent user discussion; it wasn't discussed in the MacPowerUsers comparison thread.

**Extension:** Yes, a Network Extension the user enables in System Settings.

### 2.4 TripMode

**What it is:** A data saver for metered connections such as hotspots and tethering. By default it blocks apps, and the user picks which ones may connect.

**Pricing:** It has bounced between models. The App Store version is a subscription (about $14.99/yr) with a lifetime IAP, and when a subscription lapses the app drops to a limited free mode. A one-time license from about $15 is sold direct, and it is also in Setapp. A TidBITS commenter questioned a ~$12/yr subscription for a $15 app.

**What it does well:** It switches on automatically when it detects a hotspot or iPhone tether and remembers networks. It has profiles such as "video call" and "streaming," a scheduler, data limits with warnings, and per-app reports for the last day, week and month. It also has a domains view, a live speedometer, and AppleScript and Shortcuts support. Setapp rates it about 97% positive, with comments like "an essential app for travel."

**What users complain about** (mostly from Setapp reviews):
- **Breaks networking.** One reviewer says it "constantly results in cut off WiFi connections" and another that "it breaks my Internet connection."
- **Extension setup friction.** On Sequoia the NE approval prompt never appeared, and users had to toggle it in System Settings > General > Login Items & Extensions. One user wrote "system extension didnt get enabled," and another couldn't uninstall it.
- **Reliability.** It crashes without auto-restarting, and auto on/off by connection type fails. A multi-user setup throws "No endpoint (error code = 1)," and the menu-bar window ignores Cmd-Q (Sindre Sorhus).
- **Not a monitor.** MacPowerUsers users say it's "not so great for just seeing how much data individual apps use."

**Extension:** Yes, a Network Extension.

### 2.5 iStat Menus 7 (Bjango), network module

**What it is:** A comprehensive menu-bar system monitor. Version 7 (July 2024) was a full redesign.

**Pricing:** About $11.99, or $9.99 to upgrade (Michael Tsai calls it "a bargain"). There is a family license, a 14-day trial, and Setapp. Bjango's page rendered prices as "$?" when fetched, so exact current prices are unconfirmed.

**What it does well:** Upload and download history graphs, current bandwidth and a "bandwidth breakdown for the top apps." It shows connection details, public and private IPs, link speed, VPN location flags and a connectivity indicator. Notification rules can fire when your public IP changes or the connection drops. It has heavy theming, and Bjango claims v7 uses as little as one-fifth of v6's CPU (vendor claim).

**What users complain about:** I found little direct complaint data. A Setapp reviewer said 7.3 was not compatible with the latest macOS for weeks. The MacRumors per-app thread said iStat doesn't tell you which program is hogging bandwidth and has no daily, weekly or monthly totals. That thread is old, and v7 now shows top apps live, but long-term per-app history still seems to be missing **(partly unverified)**. Michael Tsai wanted the menu to be able to record process samples.

**Extension:** No. It reads system counters, which is why it's low-friction and can't block anything.

### 2.6 Murus / Vallum

**What it is:** Murus is a GUI for macOS's built-in pf packet filter, with port-knocking, bandwidth shaping, NAT and log analysis. Vallum is a companion per-app firewall that hooks socket calls and supports silent rules or pop-up alerts.

**Pricing:** Sold as a "Pro Bundle." A Mac hosting guide cites about $35 for Murus Pro.

**Status:** Murus 2.5.1 needs macOS 10.14.4 or later. The latest Vallum changelog I found (4.1.3, Nov 2023) adds Sonoma support, and I found nothing newer. Scudo is incompatible with Big Sur and later. One catalog lists Murus as discontinued, which I couldn't confirm. These tools are relevant mostly to network admins and Mac server hosts, not mainstream users.

**Extension:** Murus uses no extension and drives pf directly. Vallum's current mechanism, kext or NE, is unconfirmed.

### 2.7 Menu-bar "net monitor" apps and Netiquette

- **Netiquette (Objective-See).** A free, open-source viewer that shows all connections and listening sockets, with filtering, export and a CLI. It was announced as a beta in 2019 and now ships inside LuLu, and it doesn't appear to be developed on its own any more. It needs no extension **(general knowledge, unverified)**.
- **Bandwidth+.** Free with IAPs and zero configuration. It counts data on the Mac it runs on and shows the current up or down rate in the menu bar; the free version shows only one value at a time. It counts LAN traffic such as Time Capsule backups, which inflates hotspot totals. There is no per-app breakdown.
- **NetWorker Pro / Lite.** Menu-bar speeds and IP, plus usage charts by day, weekday and month for data-cap watchers. It also shows active processes and open connections. Lite is free and shows speeds only; Pro is cheap (¥300 in a Japanese review).
- **Newer entrants (2025-26).** NetPulse ($2) offers per-app Top-10 by day, week and month, HTTPS-based quality metrics and VPN-vs-public-IP comparison, using an optional *observe-only* Network Extension. Others include Bytetally, NetTop, Flux, NetworkMonitor and the open-source NetFluss. This crowded low end shows that live speed in the menu bar is a commodity.
- **Network Radar.** A LAN scanner, not a traffic monitor. It discovers devices (IP, MAC, vendor, mDNS and NetBIOS names, open ports), browses Bonjour services, sends change notifications, and includes tools from Apple's removed Network Utility. A 3.2 update fixed license entry on macOS 26.

### 2.8 Debugging proxies: Charles and Proxyman

They matter here because they are what developers use to see what an app is actually sending. They are a different product category, though.

- **Charles 5** (March 2025): $50 per user, with volume and site licenses. Upgrades cost 40% of the original price, and there is a 30-day trial. Users praise it as cross-platform and long-maintained. They complain the UI is "very old" (it is a Java app with a bundled JRE) and that it "doesn't work with VPN." A German commenter still prefers it for upstream-proxy chaining in corporate networks. The trial's time-limited sessions are **(general knowledge, unverified)**.
- **Proxyman:** A native Cocoa app with a free tier that allows one debugging-tools rule and no breakpoints, Map Local, scripting or iOS apps. Paid licenses are $89 Standard and $99 Personal (2 desktop + 2 mobile seats), perpetual with 1 year of updates. Teams pay $12/seat/month. It added MCP support for AI tools. Setapp ratings are around 99%. Complaints are that it sometimes fails to capture traffic and that setup could be easier. Its docs acknowledge VPN conflicts and SSL-pinning failures. A security advisory covered its privileged helper tool in versions up to 4.10.1.
- **Lesson for Remon:** both tools need a root CA and system-proxy setup. Most users of a monitor want *who connected where and how much*, not payload inspection, so these are a separate product. They do prove there is demand for request-level detail on a per-process basis.

---

## 3. Cross-cutting themes

### 3.1 Table-stakes features
Every serious monitor in this set offers:
1. **Live per-process traffic** (bytes in/out, rate) attributed by **code-signing identity**, not just process name.
2. **Connection list** with remote hostname (not only IP), port, protocol, and **grouping by app / domain / country**.
3. **Menu-bar presence** with live up/down rates and a compact recent-activity popover.
4. **Traffic history chart** with at least day/week/month ranges.
5. **Search and filters** across apps, hosts, and time.
6. **Public/private IP, interface, VPN status**, and connectivity-loss notifications.
7. For firewalls: **allow/deny rules** with scopes and durations, **profiles per network**, **silent modes**, and **blocklist subscriptions**.
8. **Apple Silicon native, current-macOS support on day one** — users now expect this, and failure is punished.

### 3.2 Recurring pain points (things to avoid)
- **Alert fatigue / anxiety.** Prompt-driven firewalls surface hundreds of benign CDN/telemetry connections that users can't judge ("WebMD effect"). Many users quit.
- **Extension friction.** Approving system and network extensions is confusing. macOS defaults the prompt to "Don't allow," the prompts sometimes never appear (TripMode on Sequoia), extensions get stuck "pending uninstall," and uninstalling can fail.
- **Breaking the user's internet.** This is the worst failure mode. It shows up as chained NE filters corrupting SSH (LuLu #530), DNS stalls, old versions breaking networking on new macOS (Little Snitch 6.5 note), and TripMode cutting Wi-Fi.
- **macOS update fragility.** Sequoia 15.0 to 15.2 alone produced a DNS bug, a DNS-proxy bypass and a bug where firewalls got no traffic data at all. Every annual release brings a scramble.
- **OS-imposed blind spots.** The pre-handshake TCP leak, traffic that skips NE, hostname visibility limited to Network.framework clients, and the history of Apple exempting its own traffic.
- **Shallow or paywalled history.** Users ask for per-app totals by day, week and month (MacRumors). Little Snitch's chart is "too coarse," iStat focuses on live top apps, and Little Snitch Mini paywalls long history.
- **Price and model churn.** $59 for Little Snitch versus free LuLu is the most common comparison. TripMode's subscription switch drew pushback, and lifetime options are praised.
- **Dated or cluttered UI.** LuLu's terminal look and Charles's Java UI draw complaints, and Little Snitch is "overwhelming" for newcomers.

### 3.3 Gaps and opportunities for Remon
1. **"Monitor first, block optionally" with no prompts by default.** Default to observe-only, like NetPulse's observe-only NE, or to no extension at all, like iStat. Make blocking an opt-in upgrade. That avoids both alert fatigue and the risk of breaking the user's internet.
2. **Explain connections instead of asking about them.** Label destinations as Apple service, CDN, analytics/telemetry, ad network, update server or unknown, and say whether each is typical for that app. Nobody does this well, and it's the direct fix for the "WebMD effect."
3. **Durable per-process history.** Keep a local, queryable store (SwiftData or SQLite) of per-app and per-domain bytes, with day, week, month and custom ranges, exportable to CSV or JSON. This is the most consistently requested gap, and competitors either paywall it or make it coarse.
4. **Anomaly and change detection, not per-connection alerts.** Examples: "App X sent 10x its usual upload today," "new country contacted," "first connection by a newly installed binary." Batch these into a digest.
5. **Metered-network awareness without TripMode's fragility.** Detect hotspots, tethering and Low Data Mode, track usage against caps, and warn per app. This works with stat-reading alone, and blocking can stay optional.
6. **Graceful degradation and self-health.** Detect when the extension isn't receiving data (the Sequoia 15.1 failure was silent) and show a clear banner. Never fail closed in a way that kills connectivity, and ship a one-click "safe mode / uninstall extension" path.
7. **Honest attribution of blind spots.** Show "traffic not attributable to a process" as its own bucket, so totals reconcile with interface counters. That builds trust, where competitors stay quiet about leaks.
8. **Native, modern SwiftUI with good menu-bar ergonomics.** Respect Cmd-Q and keyboard navigation, show Tahoe-style icons, and offer a simple mode for newcomers with a pro mode behind it.
9. **Fair pricing.** A one-time purchase or a lifetime option is clearly preferred to subscriptions. A free monitoring tier with paid history and blocking (Little Snitch Mini's split) is a proven model, but gating basic history is resented.
10. **Light developer hooks.** Per-process request counts and hosts, plus an "open in Proxyman/Charles" hand-off, rather than building a MITM proxy.

---

## Sources

Pages actually read (fetched or summarized in search results) for this document:

- https://obdev.at/press/pr/2024-05-21-Objective-Development-Releases-Little-Snitch-6.html
- https://heise.de/en/news/Little-Snitch-6-Outbound-Firewall-bekommt-Blocklisten-und-DNS-Verschluesselung-9732997.html
- https://obdev.at/blog/apples-built-in-macos-firewall-breaks-third-party-firewalls/
- https://obdev.at/blog/should-i-upgrade-to-macos-sequoia-now/ (via search summary)
- https://tidbits.com/watchlist/little-snitch-6-5/
- https://tidbits.com/watchlist/little-snitch-6-3/ (via search summary)
- https://obdev.at/products/littlesnitch-mini/index.html
- https://obdev.at/products/littlesnitch-linux/download.html (via search summary)
- https://talk.macpowerusers.com/t/network-monitor-tripmode-vs-lulu-vs-radio-silence/27570
- https://talk.macpowerusers.com/t/little-snitch-6/37355
- https://discuss.privacyguides.net/t/why-lulu-or-little-snitch-is-not-recommended/25221
- https://forums.macrumors.com/threads/per-app-bandwidth-monitor.474475/
- https://objective-see.org/products/lulu.html
- https://github.com/objective-see/LuLu/issues
- https://github.com/objective-see/LuLu/issues/530
- https://www.patreon.com/posts/29302856 (Netiquette announcement, via search summary)
- https://mjtsai.com/blog/2021/01/14/contentfilterexclusionlist-gone-in-macos-11-2-beta-2 (via search summary)
- https://radiosilenceapp.com/
- https://radiosilenceapp.com/help/installation/ (via search summary)
- https://www.macworld.com/article/229175/radio-silence-2-review-set-it-and-forget-it-mac-firewall-for-outgoing-connections.html (via search summary)
- https://tripmode.ch/
- https://setapp.com/apps/tripmode/customer-reviews
- https://tidbits.com/watchlist/tripmode-3-0-3/ (via search summary)
- https://apps.apple.com/us/app/id1513400665 (TripMode App Store, via search summary)
- https://bjango.com/mac/istatmenus/
- https://mjtsai.com/blog/2024/08/01/istat-menus-7
- https://setapp.com/apps/istat-menus (via search summary)
- https://murusfirewall.com/comparison/
- https://murusfirewall.com/ (via search summary)
- https://apps.apple.com/us/app/bandwidth/id490461369?mt=12 (via search summary)
- https://apps.apple.com/app/id1163602886 (NetWorker Pro, via search summary)
- https://alternativeto.net/software/netpulse/about/
- https://apps.apple.com/us/app/network-radar/id507659816?mt=12 (via search summary)
- https://www.charlesproxy.com/buy/
- https://alternativeto.net/software/charles/about/
- https://proxyman.com/pricing
- https://docs.proxyman.com/troubleshooting/proxyman-does-not-work-with-vpn-apps (via search summary)
- https://setapp.com/apps/proxyman/customer-reviews (localized variants, via search summary)

**Coverage caveat:** I couldn't retrieve Reddit (r/macapps) or Hacker News threads directly; searches returned no Reddit or HN pages. User sentiment here comes from MacPowerUsers, Privacy Guides, MacRumors forums, Setapp reviews, AlternativeTo and GitHub issues. AppleInsider's Little Snitch review returned HTTP 403 and wasn't used.
