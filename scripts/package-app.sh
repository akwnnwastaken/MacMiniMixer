#!/usr/bin/env bash
#
# package-app.sh — build MacMiniMixer in Release and package it as a
# direct-distribution .zip (ad-hoc signed, NOT notarized).
#
# Usage:
#   scripts/package-app.sh [--skip-build] [--label LABEL]
#
# Options:
#   --skip-build    Reuse the existing Release build in ./.DerivedData instead of
#                   running xcodebuild.
#   --label LABEL   Append "-LABEL" to the zip name, e.g. a short commit SHA:
#                   MacMiniMixer-0.13-abc1234.zip. Allowed: letters, digits, . _ -
#                   (Can also be set with the PACKAGE_LABEL environment variable.)
#   -h, --help      Show this help.
#
# Environment:
#   DIST_DIR        Output directory (default: <repo>/dist). Relative paths are
#                   resolved against the repository root.
#   PACKAGE_LABEL   Same as --label (the flag wins if both are given).
#
# Outputs:
#   $DIST_DIR/MacMiniMixer-<version>[-<label>].zip
#   $DIST_DIR/MacMiniMixer-<version>[-<label>].zip.sha256
#
# When run inside GitHub Actions ($GITHUB_OUTPUT is set), the version, zip path
# and checksum path are also written as step outputs: version, zip, sha256.
#
# Note: written for the macOS system bash (3.2) — no bash 4+ features.

set -euo pipefail

APP_NAME="MacMiniMixer"
PROJECT="MacMiniMixer.xcodeproj"
SCHEME="MacMiniMixer"
CONFIGURATION="Release"
# Separate from the test/debug ./.DerivedData so settings from an earlier `xcodebuild test`
# (e.g. code-coverage instrumentation) can never leak into the shipped Release binary.
DERIVED_DATA_PATH="./.DerivedData-release"
PLISTBUDDY="/usr/libexec/PlistBuddy"

usage() {
  # Print the header comment block (minus the shebang) as help text.
  sed -n '3,/^$/p' "$0" | sed -e 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

# --- Arguments ---------------------------------------------------------------

SKIP_BUILD=0
LABEL="${PACKAGE_LABEL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --label)
      [ $# -ge 2 ] || die "--label needs a value"
      LABEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

if [ -n "$LABEL" ]; then
  case "$LABEL" in
    *[!A-Za-z0-9._-]*) die "label '$LABEL' may only contain letters, digits, '.', '_' and '-'" ;;
  esac
fi

# --- Environment checks ------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS (needs xcodebuild, codesign, ditto)"

for tool in xcodebuild codesign ditto shasum xattr; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[ -x "$PLISTBUDDY" ] || die "required tool not found: $PLISTBUDDY"

# Always work from the repository root so relative paths match CI and the docs.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"

# --- Build -------------------------------------------------------------------

if [ "$SKIP_BUILD" -eq 1 ]; then
  echo "==> Skipping build (--skip-build); using existing $APP_PATH"
else
  echo "==> Building $SCHEME ($CONFIGURATION)"
  # CODE_SIGNING_ALLOWED=NO: CI has no signing identity; the app is signed
  # (ad-hoc) below, after the build.
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CLANG_ENABLE_CODE_COVERAGE=NO \
    CLANG_COVERAGE_MAPPING=NO
fi

[ -d "$APP_PATH" ] || die "built app not found at $APP_PATH (run without --skip-build, or check the xcodebuild output above)"

# --- Stage a copy ------------------------------------------------------------

# Sign and zip a staged copy so the DerivedData build product is left untouched.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macminimixer-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

STAGED_APP="$STAGING_DIR/$APP_NAME.app"
ditto "$APP_PATH" "$STAGED_APP"

INFO_PLIST="$STAGED_APP/Contents/Info.plist"
[ -f "$INFO_PLIST" ] || die "Info.plist not found in $APP_PATH"

VERSION="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" \
  || die "could not read CFBundleShortVersionString from $INFO_PLIST"
BUILD_NUMBER="$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || echo "?")"
EXECUTABLE="$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || echo "$APP_NAME")"
[ -n "$VERSION" ] || die "CFBundleShortVersionString is empty in $INFO_PLIST"

echo "==> $APP_NAME version $VERSION (build $BUILD_NUMBER)"
if command -v lipo >/dev/null 2>&1; then
  echo "    architectures: $(lipo -archs "$STAGED_APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null || echo unknown)"
fi

# --- Ad-hoc sign -------------------------------------------------------------

# Why ad-hoc signing: on Apple Silicon the kernel refuses to launch arm64 code
# that has no code signature at all, so an unsigned CODE_SIGNING_ALLOWED=NO
# build is not reliably runnable once copied to another Mac. An ad-hoc
# signature ("--sign -") satisfies that requirement without any certificate.
#
# Ad-hoc signing is NOT Developer ID signing and NOT notarization: Gatekeeper
# still blocks the first launch of a downloaded copy. Users must right-click ->
# Open (macOS 13-14), use System Settings -> Privacy & Security -> "Open Anyway"
# (macOS 15+), or run:
#   xattr -dr com.apple.quarantine /Applications/MacMiniMixer.app
# See docs/RELEASING.md for the future Developer ID + notarization path.
echo "==> Ad-hoc signing"
# Extended attributes (Finder info, resource forks) make codesign fail with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$STAGED_APP"
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# --- Zip + checksum ----------------------------------------------------------

ZIP_NAME="$APP_NAME-$VERSION"
if [ -n "$LABEL" ]; then
  ZIP_NAME="$ZIP_NAME-$LABEL"
fi
ZIP_NAME="$ZIP_NAME.zip"

mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="$ZIP_PATH.sha256"
rm -f "$ZIP_PATH" "$SHA_PATH"

echo "==> Creating $ZIP_PATH"
# ditto (not zip) preserves the bundle's symlinks, permissions and signature;
# --keepParent puts MacMiniMixer.app at the top level of the archive.
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ZIP_PATH"

# Write the checksum with a bare file name so it verifies from inside dist/:
#   cd dist && shasum -a 256 -c MacMiniMixer-<version>.zip.sha256
(cd "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=$VERSION"
    echo "zip=$ZIP_PATH"
    echo "sha256=$SHA_PATH"
  } >> "$GITHUB_OUTPUT"
fi

echo
echo "Packaged $APP_NAME $VERSION (ad-hoc signed, not notarized):"
echo "  $ZIP_PATH"
echo "  $SHA_PATH"
cat "$SHA_PATH"
