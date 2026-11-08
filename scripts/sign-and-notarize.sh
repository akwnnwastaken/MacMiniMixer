#!/bin/bash
# Production staging only. Deliberately rejects embedded code until a project supplies its own signing order.
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# == 4 || $# == 5 ]] || die 'usage: sign-and-notarize.sh APP EXPECTED_ID TAG OUTPUT.zip [package-builder]'
app=$1 bundle_id=$2 tag=$3 output=$4 package_builder=${5:-}
[[ "$tag" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die 'Invalid release tag'
[[ "$output" == *.zip || ( -n "$package_builder" && "$output" == *.pkg ) ]] || die 'Invalid distribution format'
[[ ! -e "$output" && ! -e "$output.sha256" ]] || die 'Output already exists'
plist="$app/Contents/Info.plist"
[[ -d "$app" && ! -L "$app" && -f "$plist" ]] || die 'Missing app bundle'
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" == "$bundle_id" ]] || die 'Bundle ID mismatch'
[[ "v$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" == "$tag" ]] || die 'Tag does not match app version'
exe=$(plutil -extract CFBundleExecutable raw -o - "$plist")
[[ "$exe" =~ ^[A-Za-z0-9_-]+$ && -f "$app/Contents/MacOS/$exe" && ! -L "$app/Contents/MacOS/$exe" ]] || die 'Invalid main executable'
[[ -n "$(plutil -extract CFBundleVersion raw -o - "$plist")" ]] || die 'Missing bundle build number'
# Only the main Mach-O is supported by this helper. Projects with nested code must explicitly sign inside out.
while IFS= read -r -d '' file; do
  if [[ "$file" != "$app/Contents/MacOS/$exe" && "$(file -b "$file")" == *Mach-O* ]]; then
    die 'Unexpected embedded Mach-O; use a reviewed project signing plan'
  fi
done < <(find "$app" -type f -print0)
if [[ -n "$(find "$app" -type l -print)" ]]; then
  die 'Unexpected bundle symlink; use a reviewed project signing plan'
fi

: "${APPLE_TEAM_ID:?}" "${APPLE_DEVELOPER_ID_P12_BASE64:?}" "${APPLE_DEVELOPER_ID_P12_PASSWORD:?}"
: "${APPLE_NOTARY_KEY_P8_BASE64:?}" "${APPLE_NOTARY_KEY_ID:?}" "${APPLE_NOTARY_ISSUER_ID:?}"
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die 'Invalid Apple Team ID'
umask 077
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macos-sign.XXXXXXXX")
keychain="$scratch/signing.keychain-db"
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
printf '%s' "$APPLE_DEVELOPER_ID_P12_BASE64" | base64 -D > "$scratch/application.p12"
security import "$scratch/application.p12" -k "$keychain" -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
rm -f "$scratch/application.p12"
unset APPLE_DEVELOPER_ID_P12_BASE64 APPLE_DEVELOPER_ID_P12_PASSWORD
if [[ -n "$package_builder" ]]; then
  : "${APPLE_INSTALLER_P12_BASE64:?}" "${APPLE_INSTALLER_P12_PASSWORD:?}" "${APPLE_INSTALLER_IDENTITY:?}"
  [[ "$APPLE_INSTALLER_IDENTITY" == 'Developer ID Installer: '*" ($APPLE_TEAM_ID)" ]] || die 'Invalid installer identity'
  printf '%s' "$APPLE_INSTALLER_P12_BASE64" | base64 -D > "$scratch/installer.p12"
  security import "$scratch/installer.p12" -k "$keychain" -P "$APPLE_INSTALLER_P12_PASSWORD" -T /usr/bin/pkgbuild
  rm -f "$scratch/installer.p12"
  unset APPLE_INSTALLER_P12_BASE64 APPLE_INSTALLER_P12_PASSWORD
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
identity=$(security find-identity -v -p codesigning "$keychain" | awk -v team="$APPLE_TEAM_ID" '
  /"Developer ID Application: / && index($0, "(" team ")\"") { print $2; n++ }
  END { if (n != 1) exit 1 }
') || die 'Expected exactly one valid Developer ID Application identity for this team'
printf '%s' "$APPLE_NOTARY_KEY_P8_BASE64" | base64 -D > "$scratch/AuthKey.p8"
unset APPLE_NOTARY_KEY_P8_BASE64
notary=(--key "$scratch/AuthKey.p8" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")
unset APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID

verify_app() {
  local signature entitlements
  codesign --verify --deep --strict --verbose=2 "$1"
  signature=$(codesign -d --verbose=4 "$1" 2>&1)
  grep -qx "TeamIdentifier=$APPLE_TEAM_ID" <<< "$signature"
  grep -q '^Authority=Developer ID Application:' <<< "$signature"
  grep -Eq '^CodeDirectory .*flags=.*\(.*runtime' <<< "$signature"
  grep -q '^Timestamp=' <<< "$signature"
  entitlements=$(codesign -d --entitlements - "$1" 2>/dev/null)
  if [[ -n "$entitlements" ]]; then
    # The four initial apps declare no entitlements. Review and allowlist any future additions.
    [[ "$(plutil -convert json -o - -- - <<< "$entitlements")" == '{}' ]] || die 'Unexpected app entitlements'
  fi
}

notarize() {
  local status id
  rm -f "$scratch/submission.json" "$scratch/notary-log.json"
  if ! xcrun notarytool submit "$1" "${notary[@]}" --wait --timeout 35m --output-format json > "$scratch/submission.json"; then
    printf '%s\n' 'Notarytool submission/wait failed; checking for a submission ID.' >&2
  fi
  id=$(jq -er '.id | strings | select(test("^[0-9a-fA-F-]{36}$"))' "$scratch/submission.json") || die 'No valid notarization submission ID'
  status=$(jq -er '.status | strings' "$scratch/submission.json") || die "No final Apple status ($id)"
  printf 'Notarization %s: %s\n' "$id" "$status"
  xcrun notarytool log "$id" "${notary[@]}" "$scratch/notary-log.json"
  jq -e '(.issues == null or .issues == [])' "$scratch/notary-log.json" >/dev/null || die "Review Apple notarization issues for $id"
  [[ "$status" == Accepted ]] || die "Apple did not accept submission $id"
}

codesign --force --keychain "$keychain" --sign "$identity" --options runtime --timestamp "$app"
verify_app "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch/submission.zip"
notarize "$scratch/submission.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
if [[ -n "$package_builder" ]]; then
  # Builder receives no certificate password or notary credentials.
  "$package_builder" "$app" "${tag#v}" "$output" "$keychain" "$APPLE_INSTALLER_IDENTITY"
  pkg_signature=$(pkgutil --check-signature "$output")
  grep -Fq "$APPLE_INSTALLER_IDENTITY" <<< "$pkg_signature"
  notarize "$output"
  xcrun stapler staple "$output"
  xcrun stapler validate "$output"
  spctl --assess --type install --verbose=4 "$output"
  pkgutil --expand-full "$output" "$scratch/final"
  final_app="$scratch/final/Payload/Applications/${app##*/}"
else
  ditto -c -k --sequesterRsrc --keepParent "$app" "$output"
  ditto -x -k "$output" "$scratch/final"
  final_app="$scratch/final/${app##*/}"
fi
verify_app "$final_app"
xcrun stapler validate "$final_app"
spctl --assess --type execute --verbose=4 "$final_app"
(cd "$(dirname "$output")" && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
