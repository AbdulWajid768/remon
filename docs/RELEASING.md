# Releasing Remon

Remon updates itself with [Sparkle 2](https://sparkle-project.org). A running copy polls a signed
appcast once a day, and installs a new build only when two things hold: the download carries a
valid EdDSA signature from Remon's release key, and the new app is signed by the same Apple
Developer ID as the copy already installed. Neither the appcast host nor GitHub can push code to a
user's Mac without the private key.

| Piece | Where |
|---|---|
| Appcast (the feed) | `docs/appcast.xml`, served at `https://abdulwajid768.github.io/remon/appcast.xml` |
| Downloads | GitHub Releases, one `Remon-<version>.zip` per tag |
| Feed URL + public key | [Config/Info.plist](../Config/Info.plist) (`SUFeedURL`, `SUPublicEDKey`) |
| Private signing key | Login keychain of the release Mac, never in the repo |
| Updater UI | [Remon/Core/UpdateController.swift](../Remon/Core/UpdateController.swift), the **Check for Updates…** menu item, Settings → General → Updates |

A build with an empty `SUPublicEDKey` never starts the updater, so ordinary `⌘R` builds and the
E2E harness make no network calls and show no update UI.

---

## One-time setup

### 1. Apple Developer Program

Public distribution outside the Mac App Store needs a **Developer ID Application** certificate,
which requires a paid Apple Developer Program membership ($99/year). Without it macOS refuses to
open the app at all for anyone but you, and Sparkle refuses to install updates.

This Mac currently has only an *Apple Development* certificate — that one is for local runs and
cannot be used for release. In Xcode → Settings → Accounts → Manage Certificates, add a
**Developer ID Application** certificate, then confirm:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Remon is **not** sandboxed (it reads `nettop` and writes `pf` rules), so the Mac App Store is not
an option for it. Developer ID plus notarization is the only route.

### 2. A notarytool credential

Create an app-specific password at <https://appleid.apple.com> and store it once:

```bash
xcrun notarytool store-credentials remon-notary --apple-id you@example.com --team-id YOURTEAMID --password xxxx-xxxx-xxxx-xxxx
```

`remon-notary` is the profile name `scripts/release.sh` expects (override with `NOTARY_PROFILE`).

### 3. The Sparkle signing key

```bash
scripts/sparkle-keys.sh
```

This creates the EdDSA key pair, stores the private key in the login keychain, and writes the
public key into `SPARKLE_PUBLIC_ED_KEY` in the Xcode project (which becomes `SUPublicEDKey` in the
app's Info.plist). Commit the project file.

**Back the private key up now.** It lives in Keychain Access as *"Private key for signing Sparkle
updates"*; copy the password into a password manager. Every copy of Remon you ship trusts that key
and nothing else — if you lose it, existing installs can never be updated again and every user has
to download a new build by hand. `scripts/sparkle-keys.sh --show` prints the public half.

### 4. GitHub Pages

Repository → Settings → Pages → Source: *Deploy from a branch*, branch `main`, folder `/docs`.
That serves `docs/appcast.xml` at the feed URL above. `docs/.nojekyll` is there so a Jekyll build
can never fail on the Markdown in that folder and take the feed down with it. If you host the
appcast somewhere else, change `SUFeedURL` in [Config/Info.plist](../Config/Info.plist) — it must
be HTTPS, and a feed that stops resolving means no one can update.

---

## Cutting a release

```bash
scripts/release.sh 1.1
```

That bumps `MARKETING_VERSION` to 1.1 and increments the build number, archives a Release build
signed with your Developer ID, sends it to Apple's notary service and waits, staples the ticket,
verifies the result the way Gatekeeper will, zips the app, signs the zip with the Sparkle key and
adds an `<item>` to `docs/appcast.xml`. Nothing is pushed; the script prints the three commands
that publish it.

```bash
scripts/release.sh 1.1 --publish
```

does the same and then publishes: it commits and tags the version bump, pushes, creates the GitHub
release with the zip attached, and only then commits and pushes the appcast — in that order, so no
one is ever offered a download that doesn't exist yet.

Sparkle compares the **build number** (`CFBundleVersion`), not the marketing version, so the build
number must always go up. The script handles that; don't edit it by hand.

The script also starts the built app and fails if it exits straight away. That check exists because
`codesign --verify` and `spctl --assess` both pass on a build that cannot launch: under Hardened
Runtime, library validation only loads code whose Team ID matches the app's, and an ad-hoc signed
build has no Team ID, so the embedded `Sparkle.framework` is refused and the app aborts in dyld.
[Config/Remon.entitlements](../Config/Remon.entitlements) disables library validation to make
ad-hoc builds runnable. Once releases are signed with a Developer ID, Xcode re-signs Sparkle with
that same identity and the exception can be deleted.

### Release notes

Each appcast entry links to the GitHub release page, so whatever `--generate-notes` produces (or
what you write on the release afterwards) is what users read in the update window.

---

## Checking that it works

Before announcing anything, verify the whole loop on a second Mac, or on this one from a copy of
the *previous* release:

1. Install the previous version in `/Applications` and run it.
2. Publish the new version.
3. In the old copy: **Remon → Check for Updates…**. It should offer the new version, download,
   verify, relaunch, and come back on the new build.

Useful checks when something goes wrong:

```bash
curl -s https://abdulwajid768.github.io/remon/appcast.xml | head -20   # is the feed live?
spctl --assess --type execute -vvv /Applications/Remon.app             # Gatekeeper's verdict
codesign -dv --verbose=4 /Applications/Remon.app 2>&1 | grep Authority # Developer ID?
xcrun stapler validate /Applications/Remon.app                         # notarization stapled?
log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"' --level debug
```

Common causes: the app isn't in a writable location (Sparkle can't update a copy inside a
quarantined DMG or a read-only folder); the appcast's build number isn't higher than the installed
one; the zip was rebuilt after it was signed, so `sparkle:edSignature` no longer matches.

---

## What users see

- A check once a day in the background, and on demand from **Check for Updates…** in the Remon
  menu. Both are off in builds without a key.
- Settings → General → Updates: turn automatic checks off, let updates download in the background,
  the installed version, when it last checked, and a **Check Now** button.
- No system profile is ever sent with the check (`SUSendProfileInfo` is false). The request is a
  plain HTTPS GET of the appcast — the only outbound request Remon makes on its own, which the
  Privacy settings say too.
