#!/bin/bash
# Build an unsigned .ipa for sideloading (AltStore / SideStore).
#
# Unsigned on purpose: AltStore re-signs with the installing Apple ID, so a
# signing identity here would only be stripped. That also means this needs no
# DEVELOPMENT_TEAM and works on a fresh clone.
#
# ⚠️  If Config/DefaultConnection.json exists, its service-account private key is
# copied into the app bundle — and an .ipa is a zip anyone can open. This script
# refuses to build unless you acknowledge that.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

out="${1:-$HOME/Downloads}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -f Config/DefaultConnection.json ] && [ "${ALLOW_EMBEDDED_KEY:-}" != "1" ]; then
  echo "make-ipa.sh: Config/DefaultConnection.json exists — the .ipa would embed a" >&2
  echo "  service-account private key in readable form. Move it aside, or set" >&2
  echo "  ALLOW_EMBEDDED_KEY=1 if this build is only ever going on your own device." >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "make-ipa.sh: xcodegen not found" >&2; exit 1; }
xcodegen generate >/dev/null

xcodebuild archive \
  -project Repeat.xcodeproj -scheme Repeat -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/Repeat.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO >"$work/build.log" 2>&1 \
  || { tail -40 "$work/build.log" >&2; echo "make-ipa.sh: archive failed" >&2; exit 1; }

app="$work/Repeat.xcarchive/Products/Applications/Repeat.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")
ipa="$out/Repeat-$version.ipa"

mkdir -p "$work/Payload" "$out"
cp -R "$app" "$work/Payload/"
rm -f "$ipa"
(cd "$work" && zip -qry "$ipa" Payload)

# The bundle is the last place to catch a key that slipped through.
#
# The listing is captured before it is searched, not piped into `grep -q`. Under
# bash, `grep -q` exits on the first match and SIGPIPEs `unzip` (141), and with
# `set -o pipefail` that fails the whole pipeline — so the `if` was never true and
# this warning never printed, on an .ipa that did contain the key. It fired when
# tested by hand only because that shell was zsh.
listing=$(unzip -l "$ipa")
if grep -q DefaultConnection.json <<<"$listing"; then
  echo "make-ipa.sh: the .ipa contains DefaultConnection.json — do not share it." >&2
fi

echo "$ipa"
ls -lh "$ipa" | awk '{print "  " $5}'
