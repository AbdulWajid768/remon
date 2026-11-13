# Locates Sparkle's command-line tools (generate_keys, sign_update). They ship inside the
# Swift Package artifact, which only exists after the package has been resolved once.
# Sourced by sparkle-keys.sh and release.sh.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived="$repo_root/build/DerivedData"
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [[ ! -x "$sparkle_bin/sign_update" ]]; then
    echo "Resolving the Sparkle package…"
    xcodebuild -project "$repo_root/Remon.xcodeproj" -scheme Remon \
        -derivedDataPath "$derived" -resolvePackageDependencies >/dev/null
fi

if [[ ! -x "$sparkle_bin/sign_update" ]]; then
    echo "error: Sparkle's tools are not in $sparkle_bin" >&2
    exit 1
fi
