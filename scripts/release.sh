#!/bin/bash
# Builds, signs, notarizes and publishes a Remon release, and adds it to the Sparkle appcast
# every installed copy polls. See docs/RELEASING.md for the one-time setup.
#
#   scripts/release.sh 1.1              # build, notarize, update docs/appcast.xml
#   scripts/release.sh 1.1 --publish    # also create the GitHub release and push the appcast
#
# Environment:
#   DEVELOPER_ID    signing identity; default: the Developer ID Application identity in the keychain
#   TEAM_ID         Apple team ID; default: read out of DEVELOPER_ID
#   NOTARY_PROFILE  notarytool keychain profile; default: remon-notary
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

version="${1:-}"
publish="${2:-}"
if [[ -z "$version" ]]; then
    echo "usage: scripts/release.sh <version> [--publish]" >&2
    exit 2
fi

source "$repo_root/scripts/sparkle-tools.sh"

project="Remon.xcodeproj/project.pbxproj"
appcast="docs/appcast.xml"
repo_slug="$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"

# --- preflight ---------------------------------------------------------------

if grep -q 'SPARKLE_PUBLIC_ED_KEY = "";' "$project"; then
    echo "error: no Sparkle public key in the project. Run scripts/sparkle-keys.sh first." >&2
    exit 1
fi

DEVELOPER_ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | head -1)}"
if [[ -z "$DEVELOPER_ID" ]]; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "       A public release needs one (Apple Developer Program). See docs/RELEASING.md." >&2
    exit 1
fi
TEAM_ID="${TEAM_ID:-$(sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p' <<<"$DEVELOPER_ID")}"
NOTARY_PROFILE="${NOTARY_PROFILE:-remon-notary}"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "warning: the working tree has uncommitted changes; they go into this build." >&2
fi

echo "Releasing $version"
echo "  identity: $DEVELOPER_ID"
echo "  team:     $TEAM_ID"
echo

# --- version bump ------------------------------------------------------------

build_number=$(( $(sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' "$project" | sort -n | tail -1) + 1 ))
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $version;/g" "$project"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build_number;/g" "$project"
echo "Version $version, build $build_number"

# --- build, sign, notarize ---------------------------------------------------

rm -rf build/Remon.xcarchive build/export
xcodebuild -project Remon.xcodeproj -scheme Remon -configuration Release \
    -derivedDataPath build/DerivedData -archivePath build/Remon.xcarchive archive \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" | tail -3

cat > build/export-options.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath build/Remon.xcarchive \
    -exportOptionsPlist build/export-options.plist -exportPath build/export | tail -3

app="build/export/Remon.app"
echo "Submitting to the notary service (this takes a few minutes)…"
ditto -c -k --keepParent "$app" build/notarize.zip
xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"

# Gatekeeper's own verdict, the same check a first-time user's Mac makes.
codesign --verify --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"

# Neither of the checks above catches a library-validation failure: an app whose embedded
# frameworks resolve to a different Team ID verifies clean, passes Gatekeeper and still aborts
# the instant dyld maps them. The only thing that catches it is starting the app.
echo "Starting the build to check it runs..."
"$app/Contents/MacOS/Remon" >/dev/null 2>build/launch-check.log &
launch_pid=$!
sleep 10
if kill -0 "$launch_pid" 2>/dev/null; then
    kill "$launch_pid" 2>/dev/null || true
    echo "  it starts."
else
    echo "error: the build exits immediately, so it would not run on anyone's Mac." >&2
    head -5 build/launch-check.log >&2
    exit 1
fi

# --- package and sign for Sparkle --------------------------------------------

mkdir -p build/release
zip="build/release/Remon-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

signature_line="$("$sparkle_bin/sign_update" "$zip")"
signature="$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$signature_line")"
length="$(sed -nE 's/.*length="([0-9]+)".*/\1/p' <<<"$signature_line")"
if [[ -z "$signature" || -z "$length" ]]; then
    echo "error: sign_update returned '$signature_line'" >&2
    exit 1
fi

/usr/bin/python3 scripts/appcast.py \
    --appcast "$appcast" \
    --version "$version" \
    --build "$build_number" \
    --url "https://github.com/$repo_slug/releases/download/v$version/Remon-$version.zip" \
    --release-notes-url "https://github.com/$repo_slug/releases/tag/v$version" \
    --signature "$signature" \
    --length "$length"

echo
echo "Built, notarized and signed: $zip"

# --- publish -----------------------------------------------------------------

if [[ "$publish" != "--publish" ]]; then
    echo
    echo "Nothing has been published yet. To release this build, in this order:"
    echo "  git add $project && git commit -m \"Remon $version\" && git tag v$version && git push --follow-tags"
    echo "  gh release create v$version \"$zip\" --title \"Remon $version\" --generate-notes"
    echo "  git add $appcast && git commit -m \"Appcast: Remon $version\" && git push"
    exit 0
fi

# The download has to exist before the appcast points at it, or an app that checks in between
# offers an update it can't fetch.
git add "$project"
git commit -m "Remon $version"
git tag "v$version"
git push --follow-tags
gh release create "v$version" "$zip" --title "Remon $version" --generate-notes

git add "$appcast"
git commit -m "Appcast: Remon $version"
git push

echo
echo "Released. GitHub Pages takes a minute to serve the new appcast. After that, installed"
echo "copies see $version within a day, or immediately via the Check for Updates menu item."
