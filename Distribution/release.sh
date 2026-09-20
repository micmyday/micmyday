#!/bin/bash
#
# Builds, signs and packages a release, then adds it to the appcast Sparkle
# reads. It does not upload anything: the DMG is left for you to attach to a
# GitHub Release, and the appcast change is left uncommitted for you to read
# before it goes out.
#
#   Distribution/release.sh 1.1.0 42
#
# Everything here is deliberately reversible up to the moment you push, because
# an appcast entry pointing at a file that does not exist breaks the updater for
# everyone who already has the app.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLIST="MicMyDay/Resources/Info.plist"

# What shipped last, read from the file that carries it into the app. Nobody
# should have to remember which build number comes next, and a number held only
# in somebody's head is a number that eventually repeats: the App Store refuses
# a build it has seen, and Sparkle will not offer an update whose build is not
# higher than the one installed.
RELEASED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
RELEASED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"

VERSION="${1:-$RELEASED_VERSION}"
# The build always climbs, whether or not the version did: it is the identity
# of a build, not a description of it.
BUILD="${2:-$((RELEASED_BUILD + 1))}"

if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "The build number must be a whole number, not \"$BUILD\"." >&2
    exit 2
fi
if (( BUILD <= RELEASED_BUILD )); then
    echo "Build $BUILD is not above the last one ($RELEASED_BUILD)." >&2
    echo "Nothing would be able to tell the two apart: the store refuses a" >&2
    echo "repeated build, and Sparkle will not offer it as an update." >&2
    exit 2
fi

echo "==> Releasing $VERSION (build $BUILD); last was $RELEASED_VERSION (build $RELEASED_BUILD)"

ARCHIVE=".build/release-$VERSION.xcarchive"
EXPORT=".build/export-$VERSION"
DMG_DIR=".build/dmg-$VERSION"
# Deliberately without the version in it.
#
# GitHub serves a permanent redirect at releases/latest/download/<asset name>,
# which is the link a buyer can be given once and never again. It resolves only
# if the asset is called the same thing in every release, so the version lives
# in the tag and the release title instead of in the filename. Sparkle is
# unaffected: the appcast points at the tagged path below, which is a distinct
# URL per release even though the file's name never changes.
DMG=".build/MicMyDay.dmg"
APPCAST="appcast.xml"
REPO="micmyday/micmyday"
# MicMyDay's own team. This Mac holds signing identities for other teams too,
# and nothing here may ever be signed by one of them, so the team is pinned and
# verified rather than left to whichever identity Xcode finds first.
TEAM="3RF6SSDYFS"
SPARKLE_BIN=".build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin"

echo "==> Setting version to $VERSION ($BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" MicMyDay/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" MicMyDay/Resources/Info.plist
make generate >/dev/null

echo "==> Archiving"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project MicMyDay.xcodeproj -scheme MicMyDay -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates archive >/dev/null

echo "==> Exporting a Developer ID build"
# Developer ID, not App Store: this build is downloaded from a website and has
# to run on a Mac that has never seen the App Store.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist Distribution/ExportOptions-DeveloperID.plist \
    -allowProvisioningUpdates >/dev/null

echo "==> Verifying the signature belongs to us"
# A post-condition, not a hope. Automatic signing chooses an identity, and the
# only acceptable outcome is this team's Developer ID. Anything else is a
# mix-up with another account's credentials and must stop the release here,
# before a wrongly signed build is notarised or published.
# Two v's, not one. `codesign -dv` prints the team but no Authority lines at
# all, so reading the certificate name from it always came back empty and this
# check refused every build, including correctly signed ones. Both facts are
# taken from one invocation so they cannot describe different states.
SIGNED="$(codesign -dvv "$EXPORT/MicMyDay.app" 2>&1)"
SIGNED_TEAM="$(awk -F= '/^TeamIdentifier=/ {print $2}' <<<"$SIGNED")"
SIGNED_BY="$(awk -F'Authority=' '/^Authority=Developer ID Application/ {print $2; exit}' <<<"$SIGNED")"
if [[ "$SIGNED_TEAM" != "$TEAM" ]]; then
    echo "REFUSING TO CONTINUE: built app is signed by team '$SIGNED_TEAM', expected '$TEAM'." >&2
    exit 1
fi
if [[ -z "$SIGNED_BY" ]]; then
    echo "REFUSING TO CONTINUE: built app is not signed with a Developer ID Application certificate." >&2
    echo "A Developer ID signature is what lets a downloaded build launch on someone else's Mac." >&2
    exit 1
fi
echo "    signed by: $SIGNED_BY"

echo "==> Verifying this is not a build-from-source binary"
# The source build is licensed by definition and never updates itself. Shipping
# one would hand every downloader a free, unupdatable copy, and the mistake is
# invisible: it looks and runs exactly like the real thing until nobody is ever
# asked for a licence and no update ever arrives.
if [ -n "${LOCAL_BUILD:-}" ]; then
    echo "LOCAL_BUILD is set in this shell. Unset it and start again." >&2
    exit 1
fi
BUILT_AS="$(/usr/libexec/PlistBuddy -c "Print :MMDLocalBuild" \
    "$EXPORT/MicMyDay.app/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$BUILT_AS" ]; then
    echo "This app was compiled from source (MMDLocalBuild=$BUILT_AS)." >&2
    echo "It is licensed by definition and cannot update itself. Refusing to publish it." >&2
    exit 1
fi

echo "==> Verifying no test configuration was shipped"
# The sandbox organisation id is compiled only into debug builds, so finding it
# here means the release was built with the wrong configuration. Shipping it
# would send real customers' keys to a test seller that has never heard of them.
SANDBOX_ORG="115b9865-a36e-405f-91e8-a146d65b48ca"
PRODUCTION_ORG="37efa08e-0bdc-4830-83aa-7a5f6aa98271"
# Read once into a variable rather than grepping a pipeline twice.
#
# `set -o pipefail` is on, and `grep -q` stops reading the moment it matches,
# which kills `strings` upstream with SIGPIPE and makes the whole pipeline
# report failure. The test for a string that IS present therefore failed
# precisely because it was present, and refused every correctly built release.
# The test above it passed only because it never matches and so never triggers
# the early exit. One read, then two searches over what it found, and neither
# can be affected by the other's outcome.
BINARY_STRINGS="$(find "$EXPORT/MicMyDay.app/Contents/MacOS" -type f -exec strings -a {} + 2>/dev/null || true)"
if grep -q "$SANDBOX_ORG" <<<"$BINARY_STRINGS"; then
    echo "REFUSING TO CONTINUE: the sandbox licence configuration is present in this build." >&2
    exit 1
fi
if ! grep -q "$PRODUCTION_ORG" <<<"$BINARY_STRINGS"; then
    echo "REFUSING TO CONTINUE: the production licence configuration is missing from this build." >&2
    exit 1
fi

echo "==> Packaging"
rm -rf "$DMG_DIR" "$DMG"
mkdir -p "$DMG_DIR"
cp -R "$EXPORT/MicMyDay.app" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "MicMyDay" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG" >/dev/null

echo "==> Notarising (this is the slow part)"
# Credentials come from a keychain profile so no secret is written here. Create
# it once with:
#   xcrun notarytool store-credentials micmyday-notary \
#       --apple-id <you@example.com> --team-id 3RF6SSDYFS --password <app-specific>
# The profile is named for this project rather than reusing a shared default,
# so a notarisation can never go up under another account's credentials.
xcrun notarytool submit "$DMG" --keychain-profile micmyday-notary --wait
xcrun stapler staple "$DMG"

echo "==> Signing for Sparkle"
# The private key lives in the login Keychain and never leaves this machine.
# This signature is what stops a substituted download from being installed.
SIGNATURE_LINE="$("$SPARKLE_BIN/sign_update" "$DMG")"
LENGTH=$(stat -f%z "$DMG")
# The tagged path, never the "latest" one: the updater has to be offered the
# exact build this signature was made for, and a link that follows whatever is
# newest would hand it a file the signature does not match.
URL="https://github.com/$REPO/releases/download/v$VERSION/MicMyDay.dmg"

echo "==> Adding to $APPCAST"
python3 Distribution/append_appcast.py \
    --appcast "$APPCAST" \
    --version "$VERSION" \
    --build "$BUILD" \
    --url "$URL" \
    --length "$LENGTH" \
    --signature-line "$SIGNATURE_LINE"

cat <<EOF

Done. Nothing has been published yet.

  1. Read the new entry in $APPCAST and write the release notes into it.
  2. Create the GitHub release and attach the DMG. The notes must be passed
     as a file or gh stops to ask for them interactively, and --latest is
     what makes the permanent link below resolve:
       gh release create v$VERSION "$DMG" --repo $REPO --title "$VERSION" \\
           --notes-file <your notes> --latest
     Afterwards this link points at it, and keeps pointing at whatever is
     newest, so it never has to be changed anywhere it is published:
       https://github.com/$REPO/releases/latest/download/MicMyDay.dmg
  3. Commit $PLIST and $APPCAST together, and push last, once the
     download URL works. The plist is what the next release reads to know
     which build follows this one, so leaving it uncommitted is how two
     releases end up claiming the same build number.

Publishing the appcast before the file exists is the one ordering that breaks
the updater for people who already have the app.
EOF
