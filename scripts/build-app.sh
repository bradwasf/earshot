#!/bin/bash
# Builds build/Earshot.app (release) and signs it.
#
# Signing matters for privacy permissions: macOS ties the Microphone and System Audio
# grants to the app's signature. With a stable identity (any "Apple Development" certificate)
# the grants survive rebuilds; with ad-hoc signing macOS asks again after every rebuild.
# Override with EARSHOT_SIGN_ID="<identity>" or EARSHOT_SIGN_ID=- for ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Earshot.app"

echo "==> Compiling (release)"
swift build -c release --product Earshot
swift build -c release --product earshot-cli
BIN="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Earshot" "$APP/Contents/MacOS/Earshot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: Resources/AppIcon.png (regenerate with `swift scripts/make-icon.swift Resources/AppIcon.png`).
if [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null; then
    TMP="$(mktemp -d)"
    mkdir "$TMP/AppIcon.iconset"
    for size in 16 32 128 256 512; do
        sips -z $size $size Resources/AppIcon.png --out "$TMP/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$TMP/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || true
    rm -rf "$TMP"
fi

IDENTITY="${EARSHOT_SIGN_ID:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then IDENTITY="-"; fi

echo "==> Signing with: $([ "$IDENTITY" = "-" ] && echo "ad-hoc signature" || echo "$IDENTITY")"
codesign --force --sign "$IDENTITY" --identifier local.earshot.app "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"
echo "    Launch:  open $APP"
