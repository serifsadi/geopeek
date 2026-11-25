#!/bin/bash
# Archive GeoPeek for the Mac App Store and export a signed installer package.
# Marketing version and build number come from GeoPeek.xcodeproj. See RELEASING.md.
#
# This is a second archive, not a second export of the Developer ID archive.
# release.sh signs with Developer ID. App Store Connect needs Apple Distribution
# on the app and Mac Installer Distribution on the package. The distribution
# certificate for this team is cloud-managed, so the archive signs with
# automatic Apple Development and export applies the store certificates.
#
# Required environment:
#   DEVELOPMENT_TEAM   10-character Apple Developer Team ID
#
# Optional:
#   UPLOAD             set to 1 to also upload the archive to App Store Connect
#   ASC_KEY_ID         App Store Connect API key id
#   ASC_ISSUER_ID      App Store Connect API issuer id
#   ASC_KEY_PATH       path to the AuthKey .p8 file, outside this repository
#
# UPLOAD=1 requires all three key variables. When they are set without UPLOAD,
# archive and export still pass them through so provisioning does not need a
# signed-in Apple ID. The .p8 file is never written into the repository.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=release.sh
source "$script_dir/release.sh"

WORK=""
PKG_TMP=""
mas_cleanup() {
  local status=$?
  local kept
  if [[ "$status" -ne 0 && -n "$PKG_TMP" && -f "$PKG_TMP" ]]; then
    kept="${TMPDIR:-/tmp}/GeoPeek-${VERSION:-release}.pkg"
    if cp "$PKG_TMP" "$kept"; then
      echo "verification failed; kept the package at $kept" >&2
    fi
  fi
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf "$WORK"
  fi
  exit "$status"
}

require_api_key() {
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]] \
    || die "Set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH together"
  [[ -f "$ASC_KEY_PATH" ]] || die "ASC_KEY_PATH is not a file: $ASC_KEY_PATH"
  local root_real key_dir key_real
  root_real=$(cd "$ROOT" && pwd -P)
  key_dir=$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)
  key_real="$key_dir/$(basename "$ASC_KEY_PATH")"
  case "$key_real" in
    "$root_real"/*) die "ASC_KEY_PATH must be outside the repository" ;;
  esac
}

# Archive and export pass the API key through when it is set. Bash 3.2 on
# macOS treats an empty array as unbound under set -u, so the two forms are
# written out instead of sharing an argument list.
# Automatic signing with Apple Development. Manual style plus
# "Apple Distribution" looks for a local "Mac App Distribution" certificate
# and private key, and this team does not have one in the keychain. Automatic
# style accepts "Apple Development" on the command line. -allowProvisioningUpdates
# lets Xcode download profiles. ExportOptions-MAS.plist then re-signs with the
# cloud-managed Apple Distribution certificate.
# MAS_ENTITLEMENTS_SUFFIX selects the App Store entitlements, which add
# application-identifier and team-identifier. macOS export skips a profile
# for an appex whose signature does not already have those keys. An empty
# suffix, the Release default, keeps the Developer ID entitlements.
archive_app() {
  local archive="$1"
  echo "Archiving (clean Release, Apple Development)..."
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    xcodebuild clean archive \
      -project "$PROJECT" \
      -scheme GeoPeek \
      -configuration Release \
      -destination "generic/platform=macOS" \
      -archivePath "$archive" \
      -derivedDataPath "$WORK/DerivedData" \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$ASC_KEY_PATH" \
      -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      CODE_SIGN_STYLE=Automatic \
      CODE_SIGN_IDENTITY="Apple Development" \
      MAS_ENTITLEMENTS_SUFFIX=-MAS \
      ENABLE_HARDENED_RUNTIME=YES
  else
    xcodebuild clean archive \
      -project "$PROJECT" \
      -scheme GeoPeek \
      -configuration Release \
      -destination "generic/platform=macOS" \
      -archivePath "$archive" \
      -derivedDataPath "$WORK/DerivedData" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      CODE_SIGN_STYLE=Automatic \
      CODE_SIGN_IDENTITY="Apple Development" \
      MAS_ENTITLEMENTS_SUFFIX=-MAS \
      ENABLE_HARDENED_RUNTIME=YES
  fi
}

export_archive() {
  local archive="$1"
  local plist="$2"
  local dest="$3"
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    xcodebuild -exportArchive \
      -archivePath "$archive" \
      -exportPath "$dest" \
      -exportOptionsPlist "$plist" \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$ASC_KEY_PATH" \
      -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  else
    xcodebuild -exportArchive \
      -archivePath "$archive" \
      -exportPath "$dest" \
      -exportOptionsPlist "$plist" \
      -allowProvisioningUpdates
  fi
}

assert_store_metadata() {
  local app="$1"
  local plist category encryption copyright privacy
  plist="$app/Contents/Info.plist"
  category=$("$PLISTBUDDY" -c "Print :LSApplicationCategoryType" "$plist" 2>/dev/null || true)
  [[ "$category" == "public.app-category.developer-tools" ]] \
    || die "LSApplicationCategoryType is '$category', expected public.app-category.developer-tools"
  encryption=$("$PLISTBUDDY" -c "Print :ITSAppUsesNonExemptEncryption" "$plist" 2>/dev/null || true)
  [[ "$encryption" == "false" ]] \
    || die "ITSAppUsesNonExemptEncryption is '$encryption', expected false"
  copyright=$("$PLISTBUDDY" -c "Print :NSHumanReadableCopyright" "$plist" 2>/dev/null || true)
  [[ -n "$copyright" ]] || die "NSHumanReadableCopyright is empty"
  [[ -f "$app/Contents/Resources/Credits.html" ]] \
    || die "GeoPeek.app is missing Contents/Resources/Credits.html"
  grep -q "See Help &gt; Acknowledgements." "$app/Contents/Resources/Credits.html" \
    || die "Credits.html is missing the Help menu line"
  grep -q "text-align: center" "$app/Contents/Resources/Credits.html" \
    || die "Credits.html credits are not center aligned"
  [[ -f "$app/Contents/Resources/ThirdPartyNotices.txt" ]] \
    || die "GeoPeek.app is missing Contents/Resources/ThirdPartyNotices.txt"
  grep -q "BEGIN MAPLIBRE-GL-JS-5.24.1 LICENSE" "$app/Contents/Resources/ThirdPartyNotices.txt" \
    || die "ThirdPartyNotices.txt in the app is missing the MapLibre license"
  privacy="$app/Contents/Resources/PrivacyInfo.xcprivacy"
  if [[ ! -f "$privacy" ]]; then
    privacy="$app/Contents/PrivacyInfo.xcprivacy"
  fi
  [[ -f "$privacy" ]] || die "GeoPeek.app is missing PrivacyInfo.xcprivacy"
  grep -q "NSPrivacyAccessedAPICategoryUserDefaults" "$privacy" \
    || die "privacy manifest does not declare UserDefaults"
  grep -q "CA92.1" "$privacy" \
    || die "privacy manifest is missing the UserDefaults reason CA92.1"
}

# Export embeds a profile only when the signature already has
# com.apple.application-identifier. Sandbox entitlements alone do not.
# The profile's application-identifier is TEAMID.bundle-id.
assert_appex_profile() {
  local appex="$1"
  local bundle_id="$2"
  local name profile decoded app_id ents
  name=$(basename "$appex")
  profile="$appex/Contents/embedded.provisionprofile"
  [[ -f "$profile" ]] || die "$name is missing Contents/embedded.provisionprofile"
  decoded=$(mktemp "${TMPDIR:-/tmp}/geopeek-profile.XXXXXX")
  if ! security cms -D -i "$profile" > "$decoded"; then
    rm -f "$decoded"
    die "could not decode the provisioning profile in $name"
  fi
  app_id=$("$PLISTBUDDY" -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null || true)
  rm -f "$decoded"
  [[ "$app_id" == "$DEVELOPMENT_TEAM.$bundle_id" ]] \
    || die "$name profile application-identifier is '$app_id', expected $DEVELOPMENT_TEAM.$bundle_id"
  ents=$(codesign -d --entitlements :- "$appex" 2>&1) || die "could not read entitlements of $name"
  entitlement_present "$ents" "com.apple.application-identifier" \
    || die "$name signature has no application-identifier"
}

# Developer ID signatures include Timestamp=. App Store signatures have a
# Signed Time and no secure timestamp. Requiring Timestamp= rejects a valid
# App Store export. Hardened runtime is still required.
assert_store_runtime() {
  local target="$1"
  local label="$2"
  local info
  info=$(codesign -dv --verbose=4 "$target" 2>&1) || die "codesign could not read $label"
  printf '%s\n' "$info" | grep -q 'flags=.*runtime' || die "$label is signed without the hardened runtime"
}

assert_store_product() {
  local bundle="$1"
  assert_bundle_layout "$bundle"
  assert_versions "$bundle" "GeoPeek.app"
  assert_versions "$bundle/Contents/PlugIns/GeoPeekExtension.appex" "GeoPeekExtension.appex"
  assert_versions "$bundle/Contents/PlugIns/GeoPeekThumbnailExtension.appex" "GeoPeekThumbnailExtension.appex"
  assert_store_runtime "$bundle" "GeoPeek.app"
  assert_store_runtime "$bundle/Contents/PlugIns/GeoPeekExtension.appex" "GeoPeekExtension.appex"
  assert_store_runtime "$bundle/Contents/PlugIns/GeoPeekThumbnailExtension.appex" "GeoPeekThumbnailExtension.appex"
  assert_entitlements "$bundle" "GeoPeek.app" "yes"
  assert_entitlements "$bundle/Contents/PlugIns/GeoPeekExtension.appex" "GeoPeekExtension.appex" "yes"
  assert_entitlements "$bundle/Contents/PlugIns/GeoPeekThumbnailExtension.appex" "GeoPeekThumbnailExtension.appex" "no"
  codesign --verify --deep --strict --verbose=2 "$bundle"
}

assert_appex_profiles() {
  local app="$1"
  assert_appex_profile "$app/Contents/PlugIns/GeoPeekExtension.appex" \
    "dev.serifsadi.GeoPeek.GeoPeekExtension"
  assert_appex_profile "$app/Contents/PlugIns/GeoPeekThumbnailExtension.appex" \
    "dev.serifsadi.GeoPeek.GeoPeekThumbnailExtension"
}

assert_distribution_signature() {
  local app="$1"
  local authority
  authority=$(signing_authority "$app") || die "could not read the signing authority of $app"
  [[ -n "$authority" ]] || die "could not read the signing authority of $app"
  case "$authority" in
    "Apple Distribution:"*"($DEVELOPMENT_TEAM)") ;;
    "3rd Party Mac Developer Application:"*"($DEVELOPMENT_TEAM)") ;;
    *) die "app is signed by '$authority', expected Apple Distribution for team $DEVELOPMENT_TEAM" ;;
  esac
}

assert_pkg_signature() {
  local pkg="$1"
  local sig
  sig=$(pkgutil --check-signature "$pkg" 2>&1) || die "pkgutil rejected $pkg:"$'\n'"$sig"
  printf '%s\n' "$sig"
  printf '%s\n' "$sig" | grep -q "$DEVELOPMENT_TEAM" \
    || die "package is not signed for team $DEVELOPMENT_TEAM"
  if printf '%s\n' "$sig" | grep -q "Developer ID"; then
    die "package is Developer ID signed; App Store export should use the Mac installer certificate"
  fi
}

# One GeoPeek.app that contains the Quick Look extension. A second copy means
# the package layout is not the one this script knows how to check.
expanded_app() {
  local pkg="$1"
  local dest="$2"
  local expanded found path count app
  expanded="$dest/expanded"
  rm -rf "$expanded"
  mkdir -p "$dest"
  pkgutil --expand-full "$pkg" "$expanded" >/dev/null || die "could not expand $pkg"
  found=$(find "$expanded" -type d -name 'GeoPeek.app' -print || true)
  count=0
  app=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -d "$path/Contents/PlugIns/GeoPeekExtension.appex" ]] || continue
    count=$((count + 1))
    app=$path
  done <<EOF
$found
EOF
  [[ "$count" -eq 1 ]] || die "expanded package should contain one GeoPeek.app with the Quick Look extension, found $count"
  printf '%s\n' "$app"
}

main() {
  ROOT=$(cd "$script_dir/.." && pwd)
  PROJECT="$ROOT/GeoPeek.xcodeproj"
  PBXPROJ="$PROJECT/project.pbxproj"
  PLISTBUDDY=/usr/libexec/PlistBuddy

  [[ -n "${DEVELOPMENT_TEAM:-}" ]] || die "Set DEVELOPMENT_TEAM to the Apple Developer Team ID"
  [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "DEVELOPMENT_TEAM must be a 10-character Team ID"
  case "${UPLOAD:-}" in
    ""|0) ;;
    1) ;;
    *) die "UPLOAD must be 1 or unset" ;;
  esac
  if [[ -n "${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}${ASC_KEY_PATH:-}" || "${UPLOAD:-}" == "1" ]]; then
    require_api_key
  fi

  load_project_versions
  echo "Project version ${VERSION} (${BUILD})"

  local export_template="$script_dir/ExportOptions-MAS.plist"
  [[ -f "$export_template" ]] || die "ExportOptions template not found: $export_template"
  [[ -x "$PLISTBUDDY" ]] || die "PlistBuddy is not at $PLISTBUDDY"
  local method style
  method=$("$PLISTBUDDY" -c "Print :method" "$export_template")
  style=$("$PLISTBUDDY" -c "Print :signingStyle" "$export_template")
  [[ "$method" == "app-store-connect" ]] || die "ExportOptions-MAS.plist method is '$method', expected app-store-connect"
  [[ "$style" == "automatic" ]] || die "ExportOptions-MAS.plist signingStyle is '$style', expected automatic"
  local manage_versions
  manage_versions=$("$PLISTBUDDY" -c "Print :manageAppVersionAndBuildNumber" "$export_template" 2>/dev/null || true)
  [[ "$manage_versions" == "false" ]] || die "ExportOptions-MAS.plist must set manageAppVersionAndBuildNumber to false"

  require_cmd xcodebuild
  require_cmd xcrun
  require_cmd codesign
  require_cmd security
  require_cmd pkgutil
  require_cmd find

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/geopeek-mas.XXXXXX")
  trap mas_cleanup EXIT

  local archive="$WORK/GeoPeek.xcarchive"
  local export_dir="$WORK/export"
  local export_plist="$WORK/ExportOptions.plist"
  local pkg_final="$ROOT/GeoPeek-${VERSION}.pkg"

  archive_app "$archive"

  cp "$export_template" "$export_plist"
  "$PLISTBUDDY" -c "Set :teamID $DEVELOPMENT_TEAM" "$export_plist"
  "$PLISTBUDDY" -c "Set :destination export" "$export_plist"

  echo "Exporting App Store package..."
  mkdir -p "$export_dir"
  export_archive "$archive" "$export_plist" "$export_dir"

  local pkg pkg_count
  # Count first. Two packages make -f fail on the combined find output, which
  # would hide this message.
  pkg_count=$(find "$export_dir" -maxdepth 1 -name '*.pkg' -print | grep -c . || true)
  [[ "$pkg_count" -eq 1 ]] || die "export produced $pkg_count packages, expected 1"
  pkg=$(find "$export_dir" -maxdepth 1 -name '*.pkg' -print || true)
  [[ -n "$pkg" && -f "$pkg" ]] || die "export did not produce a .pkg in $export_dir"
  PKG_TMP=$pkg

  assert_pkg_signature "$pkg"
  local app
  app=$(expanded_app "$pkg" "$WORK/pkg-expand") || die "could not read GeoPeek.app from $pkg"
  assert_store_product "$app"
  assert_distribution_signature "$app"
  assert_store_metadata "$app"
  assert_appex_profiles "$app"

  rm -f "$pkg_final"
  mv "$pkg" "$pkg_final"
  PKG_TMP=""
  echo ""
  echo "GeoPeek ${VERSION} (${BUILD})"
  echo "$pkg_final"
  du -h "$pkg_final" | awk '{ print $1 }'

  if [[ "${UPLOAD:-}" == "1" ]]; then
    local upload_plist="$WORK/ExportOptions-upload.plist"
    local upload_dir="$WORK/upload"
    cp "$export_plist" "$upload_plist"
    "$PLISTBUDDY" -c "Set :destination upload" "$upload_plist"
    mkdir -p "$upload_dir"
    echo "Uploading to App Store Connect..."
    export_archive "$archive" "$upload_plist" "$upload_dir"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
