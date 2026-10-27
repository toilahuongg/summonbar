#!/bin/bash
# Build Summonbar.app.
#   --install   copy it to ~/Applications and launch it
#   --release   universal build, zipped to build/Summonbar-<version>.zip
#               (notarized and stapled first when signed with Developer ID)
#
# Signing: SIGN_IDENTITY names the certificate. Left unset, the first
# "Developer ID Application" identity in the keychain is used, then the first
# "Apple Development" one, or ad-hoc ("-") if there is neither. --release needs a
# certificate. Only Developer ID can be notarized, which needs credentials:
# NOTARY_PROFILE (a profile saved with `xcrun notarytool store-credentials`), or
# NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER (an App Store Connect API key).
# An Apple Development release isn't notarized, so Gatekeeper asks on first open.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
APP=build/Summonbar.app

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
  for KIND in "Developer ID Application" "Apple Development"; do
    SIGN_IDENTITY=$(awk -F'"' -v kind="$KIND" 'index($2, kind) == 1 { print $2; exit }' <<<"$IDENTITIES")
    [[ -n "$SIGN_IDENTITY" ]] && break
  done
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [[ "$MODE" == "--release" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "error: --release needs a signing certificate (Developer ID or Apple Development, or set SIGN_IDENTITY)" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BUILD_FLAGS=(-c release)
# A universal build needs full Xcode, not just the Command Line Tools.
[[ "$MODE" == "--release" ]] && BUILD_FLAGS+=(--arch arm64 --arch x86_64)
swift build "${BUILD_FLAGS[@]}"
cp "$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/Summonbar" "$APP/Contents/MacOS/Summonbar"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Summonbar")
if [[ "$MODE" == "--release" && ( "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ) ]]; then
  echo "error: the release binary isn't universal" >&2
  exit 1
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # Ad-hoc: macOS ties launch at login to this build's cdhash, so it resets on every rebuild.
  codesign --force --sign - "$APP" >/dev/null
else
  # A certificate keeps the login item across updates (it's keyed to the team, not
  # the cdhash). Notarization also needs the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed with $SIGN_IDENTITY)"

if [[ "$MODE" == "--release" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  ZIP="build/Summonbar-$VERSION.zip"
  rm -f "$ZIP"
  if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    else
      NOTARY_AUTH=(--key "${NOTARY_KEY:?set NOTARY_PROFILE or NOTARY_KEY}" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
    fi
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
    # Staple the ticket so Gatekeeper accepts the app offline, then zip the stapled app.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    spctl --assess --type execute "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Notarized $ZIP"
  else
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Zipped $ZIP (not notarized: only Developer ID can be)"
  fi
fi

if [[ "$MODE" == "--install" ]]; then
  pkill -x Summonbar 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Summonbar.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Summonbar.app
  echo "Installed ~/Applications/Summonbar.app"
fi
