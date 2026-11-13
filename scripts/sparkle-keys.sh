#!/bin/bash
# Creates the EdDSA key pair Sparkle uses to sign releases, and writes the public half into the
# Xcode project (SPARKLE_PUBLIC_ED_KEY -> SUPublicEDKey in Info.plist). Run this once, ever.
#
# The private key is stored in the login keychain of this Mac and is never written to the repo.
# Back it up (Keychain Access -> "Private key for signing Sparkle updates" -> copy the password):
# losing it means existing installs can't be updated, because they only trust this key.
set -euo pipefail

source "$(dirname "$0")/sparkle-tools.sh"

if [[ "${1:-}" == "--show" ]]; then
    "$sparkle_bin/generate_keys" -p
    exit 0
fi

"$sparkle_bin/generate_keys"
public_key="$("$sparkle_bin/generate_keys" -p)"

if [[ -z "$public_key" ]]; then
    echo "error: no public key came back from generate_keys" >&2
    exit 1
fi

project="$repo_root/Remon.xcodeproj/project.pbxproj"
/usr/bin/python3 -c '
import re, sys
path, key = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r"SPARKLE_PUBLIC_ED_KEY = \"[^\"]*\";", "SPARKLE_PUBLIC_ED_KEY = \"%s\";" % key, s)
if n == 0:
    sys.exit("error: SPARKLE_PUBLIC_ED_KEY is not in the project file")
open(path, "w").write(s)
print("Wrote the public key into %d build configurations." % n)
' "$project" "$public_key"

echo
echo "Public key: $public_key"
echo "Commit the project file. Keep the private key safe — it is the only thing that can sign"
echo "updates existing installs will accept."
