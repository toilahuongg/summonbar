#!/bin/bash
# Build Summonbar.app.
#   --install   copy it to ~/Applications and launch it
#   --release   universal build, notarized and stapled, zipped to build/Summonbar-<version>.zip
#
# Signing: SIGN_IDENTITY names the certificate. Left unset, the first
# "Developer ID Application" identity in the keychain is used, or ad-hoc ("-")
# if there is none. --release needs Developer ID, plus notarization credentials:
# NOTARY_PROFILE (a profile saved with `xcrun notarytool store-credentials`), or
# NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER (an App Store Connect API key, as CI uses).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
APP=build/Summonbar.app

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [[ "$MODE" == "--release" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "error: --release needs a Developer ID Application identity (set SIGN_IDENTITY)" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$MODE" == "--release" ]]; then
  # One build per architecture, joined with lipo (`--arch a --arch b` needs full Xcode).
  BINS=()
  for ARCH in arm64 x86_64; do
    swift build -c release --triple "$ARCH-apple-macosx14.0"
    BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Summonbar")
  done
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Summonbar"
else
  swift build -c release
  cp .build/release/Summonbar "$APP/Contents/MacOS/Summonbar"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # Ad-hoc: macOS ties launch at login to this build's cdhash, so it resets on every rebuild.
  codesign --force --sign - "$APP" >/dev/null
else
  # Notarization needs the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed with $SIGN_IDENTITY)"

if [[ "$MODE" == "--release" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  ZIP="build/Summonbar-$VERSION.zip"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  else
    NOTARY_AUTH=(--key "${NOTARY_KEY:?set NOTARY_PROFILE or NOTARY_KEY}" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
  fi
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
  # Staple the ticket so Gatekeeper accepts the app offline, then zip the stapled app.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute "$APP"
  echo "Notarized $ZIP"
fi

if [[ "$MODE" == "--install" ]]; then
  pkill -x Summonbar 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Summonbar.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Summonbar.app
  echo "Installed ~/Applications/Summonbar.app"
fi
