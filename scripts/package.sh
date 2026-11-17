#!/bin/bash
# Packages Earshot for other people: builds the app and writes dist/Earshot-<version>.dmg
# (the app, an Applications shortcut and SETUP.md as "Read Me First.txt").
#
#   scripts/package.sh             build the disk image
#   scripts/package.sh --release   also publish it as GitHub release v<version> (needs `gh`)
#
# The version comes from CFBundleShortVersionString in Resources/Info.plist. Bump it there for
# a new release, or override it for one run with EARSHOT_VERSION=1.1.
#
# Signing, in order of preference:
#   1. EARSHOT_DIST_SIGN_ID="<identity>" if set ("-" forces ad-hoc).
#   2. A "Developer ID Application" certificate in the keychain: signed with the hardened
#      runtime, and notarized + stapled when EARSHOT_NOTARY_PROFILE names a notarytool keychain
#      profile (`xcrun notarytool store-credentials <name>`). Recipients then get no Gatekeeper
#      warning. This path has not been exercised yet: no Developer ID exists on the Mac this
#      script was written on.
#   3. Otherwise ad-hoc. Recipients approve the app once in System Settings (see SETUP.md).
#      An "Apple Development" certificate is deliberately not used: it does not satisfy
#      Gatekeeper either, and it would embed the developer's Apple ID e-mail in a public file.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=0
for argument in "$@"; do
    case "$argument" in
        --release) RELEASE=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

VERSION="${EARSHOT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
TAG="v$VERSION"
DMG="dist/Earshot-$VERSION.dmg"

if [ "$RELEASE" -eq 1 ]; then
    # Check everything a release needs before spending time on the build.
    command -v gh >/dev/null || die "--release needs the GitHub CLI (gh)."
    [ -z "$(git status --porcelain)" ] || die "Commit or stash your changes first, so the release matches a commit."
    git fetch --quiet origin
    [ -n "$(git branch -r --contains HEAD)" ] || die "Push this commit first, so the release tag can point at it."
    if gh release view "$TAG" >/dev/null 2>&1; then
        die "Release $TAG already exists. Bump CFBundleShortVersionString in Resources/Info.plist."
    fi
fi

step "Building Earshot $VERSION ($BUILD_NUMBER)"
./scripts/build-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Earshot.app"
cp -R build/Earshot.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
xattr -cr "$APP"

IDENTITY="${EARSHOT_DIST_SIGN_ID:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
[ -n "$IDENTITY" ] || IDENTITY="-"

if [ "$IDENTITY" = "-" ]; then
    step "Signing: ad-hoc (not notarized; recipients approve the app once, see SETUP.md)"
    codesign --force --sign - --identifier local.earshot.app "$APP"
else
    step "Signing: $IDENTITY (hardened runtime)"
    codesign --force --sign "$IDENTITY" --identifier local.earshot.app --options runtime --timestamp \
        --entitlements Resources/Earshot.entitlements "$APP"
fi
codesign --verify --strict --deep "$APP"

step "Creating $DMG"
ln -s /Applications "$STAGE/Applications"
cp SETUP.md "$STAGE/Read Me First.txt"
mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname "Earshot $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"

if [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    if [ -n "${EARSHOT_NOTARY_PROFILE:-}" ]; then
        step "Notarizing (this waits for Apple, usually a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$EARSHOT_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    else
        echo "    Not notarized: set EARSHOT_NOTARY_PROFILE to a notarytool keychain profile to notarize."
    fi
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "$SHA  $(basename "$DMG")" > "$DMG.sha256"

if [ "$RELEASE" -eq 1 ]; then
    step "Publishing GitHub release $TAG"
    REPO_URL="$(gh repo view --json url --jq .url)"
    # Uploaded under a fixed name so that <repo>/releases/latest/download/Earshot.dmg always
    # fetches the newest version (that is the link in SETUP.md).
    cp "$DMG" "$STAGE/Earshot.dmg"
    cat > "$STAGE/notes.md" <<EOF
Earshot $VERSION for Apple Silicon Macs running macOS 14.4 or newer.

**Install:** download \`Earshot.dmg\` below, open it, and drag Earshot into Applications. Then follow the [setup guide]($REPO_URL/blob/$TAG/SETUP.md): the app is not notarized by Apple, so macOS asks you to approve it once before the first launch.

SHA-256 of \`Earshot.dmg\`: \`$SHA\`
EOF
    gh release create "$TAG" "$STAGE/Earshot.dmg" --target "$(git rev-parse HEAD)" \
        --title "Earshot $VERSION" --notes-file "$STAGE/notes.md"
    echo "    $REPO_URL/releases/tag/$TAG"
    echo "    Direct download: $REPO_URL/releases/latest/download/Earshot.dmg"
fi

step "Done"
echo "    $(pwd)/$DMG  ($(du -h "$DMG" | awk '{print $1}'))"
echo "    sha256 $SHA"
