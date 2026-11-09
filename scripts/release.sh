#!/bin/bash
# Archive GeoPeek, export a Developer ID build, and write a notarized disk image.
# Marketing version and build number come from GeoPeek.xcodeproj. See RELEASING.md.
#
# Required environment:
#   DEVELOPMENT_TEAM   10-character Apple Developer Team ID
#   NOTARY_PROFILE     keychain profile from `xcrun notarytool store-credentials`
#
# Optional:
#   SIGN_IDENTITY      certificate name used to sign the disk image
#                      (default: the Developer ID that signed the app)

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  local hint="${2:-}"
  command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH${hint:+. $hint}"
}

# Every MARKETING_VERSION / CURRENT_PROJECT_VERSION line in the project.
setting_values() {
  local key="$1"
  local lines
  lines=$(grep -E "^[[:space:]]*${key} = " "$PBXPROJ" || true)
  [[ -n "$lines" ]] || die "project has no ${key}"
  printf '%s\n' "$lines" | sed -E "s/.*${key} = ([^;]+);/\\1/"
}

# Three targets, Debug and Release. One value, or stop before a build.
load_project_versions() {
  local values uniq count
  values=$(setting_values MARKETING_VERSION)
  uniq=$(printf '%s\n' "$values" | sort -u)
  count=$(printf '%s\n' "$values" | wc -l | tr -d ' ')
  [[ "$count" -eq 6 ]] || die "expected 6 MARKETING_VERSION assignments, found $count"
  case "$uniq" in
    *$'\n'*) die "MARKETING_VERSION disagrees across the project:"$'\n'"$uniq" ;;
  esac
  VERSION=$uniq
  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "MARKETING_VERSION '$VERSION' is not a dotted version"

  values=$(setting_values CURRENT_PROJECT_VERSION)
  uniq=$(printf '%s\n' "$values" | sort -u)
  count=$(printf '%s\n' "$values" | wc -l | tr -d ' ')
  [[ "$count" -eq 6 ]] || die "expected 6 CURRENT_PROJECT_VERSION assignments, found $count"
  case "$uniq" in
    *$'\n'*) die "CURRENT_PROJECT_VERSION disagrees across the project:"$'\n'"$uniq" ;;
  esac
  BUILD=$uniq
  [[ "$BUILD" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION '$BUILD' is not a number"
}

# A sealed app bundle's only top-level entry is Contents. The 0.2.0 disk
# image had a second GeoPeek.app beside Contents, outside the signature.
assert_bundle_layout() {
  local bundle="$1"
  local path base rel nested
  [[ -d "$bundle/Contents" ]] || die "$bundle has no Contents directory"
  for path in "$bundle"/*; do
    base=$(basename "$path")
    [[ "$base" == "Contents" ]] || die "unexpected item beside Contents: $path"
  done
  nested=$(find "$bundle" -mindepth 1 -name '*.app' -print || true)
  if [[ -n "$nested" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      rel=${path#"$bundle"/}
      case "$rel" in
        Contents/*) ;;
        *) die "nested .app outside Contents: $path" ;;
      esac
    done <<EOF
$nested
EOF
  fi
}

assert_versions() {
  local bundle="$1"
  local label="$2"
  local plist short build
  plist="$bundle/Contents/Info.plist"
  [[ -f "$plist" ]] || die "$label has no Info.plist ($plist)"
  short=$("$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$plist")
  build=$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$plist")
  [[ "$short" == "$VERSION" ]] || die "$label CFBundleShortVersionString is '$short', project MARKETING_VERSION is '$VERSION'"
  [[ "$build" == "$BUILD" ]] || die "$label CFBundleVersion is '$build', project CURRENT_PROJECT_VERSION is '$BUILD'"
}

assert_runtime() {
  local target="$1"
  local label="$2"
  local info
  info=$(codesign -dv --verbose=4 "$target" 2>&1) || die "codesign could not read $label"
  printf '%s\n' "$info" | grep -q 'flags=.*runtime' || die "$label is signed without the hardened runtime"
  printf '%s\n' "$info" | grep -q '^Timestamp=' || die "$label has no secure timestamp"
}

# codesign prints XML with --entitlements :- and the older [Key]/[Bool] form otherwise.
entitlement_is_true() {
  local xml="$1"
  local key="$2"
  local block
  block=$(printf '%s\n' "$xml" | grep -A1 -F "<key>${key}</key>" || true)
  if printf '%s\n' "$block" | grep -Eq '<true[[:space:]]*/>'; then
    return 0
  fi
  block=$(printf '%s\n' "$xml" | grep -A2 -F "[Key] ${key}" || true)
  if printf '%s\n' "$block" | grep -q -F "[Bool] true"; then
    return 0
  fi
  return 1
}

entitlement_present() {
  local xml="$1"
  local key="$2"
  if printf '%s\n' "$xml" | grep -q -F "<key>${key}</key>"; then
    return 0
  fi
  if printf '%s\n' "$xml" | grep -q -F "[Key] ${key}"; then
    return 0
  fi
  return 1
}

require_true() {
  local xml="$1"
  local key="$2"
  local label="$3"
  entitlement_is_true "$xml" "$key" || die "$label is missing entitlement $key"
}

forbid_key() {
  local xml="$1"
  local key="$2"
  local label="$3"
  if entitlement_present "$xml" "$key"; then
    die "$label includes $key"
  fi
}

# network is "yes" for the app and the Quick Look preview, "no" for the thumbnail.
assert_entitlements() {
  local target="$1"
  local label="$2"
  local network="$3"
  local ents
  ents=$(codesign -d --entitlements :- "$target" 2>&1) || die "could not read entitlements of $label"
  require_true "$ents" "com.apple.security.app-sandbox" "$label"
  require_true "$ents" "com.apple.security.files.user-selected.read-only" "$label"
  if [[ "$network" == "yes" ]]; then
    require_true "$ents" "com.apple.security.network.client" "$label"
  else
    forbid_key "$ents" "com.apple.security.network.client" "$label"
  fi
  if printf '%s\n' "$ents" | grep -q -F "com.apple.security.cs."; then
    die "$label has a hardened runtime exception (com.apple.security.cs.*)"
  fi
  forbid_key "$ents" "com.apple.security.get-task-allow" "$label"
}

assert_product() {
  local bundle="$1"
  assert_bundle_layout "$bundle"
  assert_versions "$bundle" "GeoPeek.app"
  assert_versions "$bundle/Contents/PlugIns/GeoPeekExtension.appex" "GeoPeekExtension.appex"
  assert_versions "$bundle/Contents/PlugIns/GeoPeekThumbnailExtension.appex" "GeoPeekThumbnailExtension.appex"
  assert_runtime "$bundle" "GeoPeek.app"
  assert_runtime "$bundle/Contents/PlugIns/GeoPeekExtension.appex" "GeoPeekExtension.appex"
  assert_runtime "$bundle/Contents/PlugIns/GeoPeekThumbnailExtension.appex" "GeoPeekThumbnailExtension.appex"
  assert_entitlements "$bundle" "GeoPeek.app" "yes"
  assert_entitlements "$bundle/Contents/PlugIns/GeoPeekExtension.appex" "GeoPeekExtension.appex" "yes"
  assert_entitlements "$bundle/Contents/PlugIns/GeoPeekThumbnailExtension.appex" "GeoPeekThumbnailExtension.appex" "no"
  codesign --verify --deep --strict --verbose=2 "$bundle"
}

spctl_exec() {
  local target="$1"
  local out
  out=$(spctl -a -vv -t exec "$target" 2>&1) || die "spctl rejected $target:"$'\n'"$out"
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -qi "accepted" || die "spctl did not accept $target"
}

spctl_dmg() {
  local target="$1"
  local out
  out=$(spctl -a -vv -t open --context context:primary-signature "$target" 2>&1) || die "spctl rejected $target:"$'\n'"$out"
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -qi "accepted" || die "spctl did not accept $target"
}

signing_authority() {
  local target="$1"
  local info
  info=$(codesign -dv --verbose=4 "$target" 2>&1) || return 1
  printf '%s\n' "$info" | awk '/^Authority=/ && !found { print substr($0, index($0, "=") + 1); found = 1 }'
}

WORK=""
MOUNT_POINT=""
DMG_TMP=""
cleanup() {
  local status=$?
  local kept
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [[ "$status" -ne 0 && -n "$DMG_TMP" && -f "$DMG_TMP" ]]; then
    kept="${TMPDIR:-/tmp}/GeoPeek-${VERSION:-release}.dmg"
    if cp "$DMG_TMP" "$kept"; then
      echo "verification failed; kept the disk image at $kept" >&2
    fi
  fi
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    cd /
    rm -rf "$WORK"
  fi
  exit "$status"
}

main() {
  local script_dir root project
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  root=$(cd "$script_dir/.." && pwd)
  project="$root/GeoPeek.xcodeproj"
  PBXPROJ="$project/project.pbxproj"
  PLISTBUDDY=/usr/libexec/PlistBuddy

  [[ -n "${DEVELOPMENT_TEAM:-}" ]] || die "Set DEVELOPMENT_TEAM to the Apple Developer Team ID"
  [[ -n "${NOTARY_PROFILE:-}" ]] || die "Set NOTARY_PROFILE to the name used with notarytool store-credentials"
  [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "DEVELOPMENT_TEAM must be a 10-character Team ID"

  load_project_versions
  echo "Project version ${VERSION} (${BUILD})"

  local background="$script_dir/dmg_background.png"
  local export_template="$script_dir/ExportOptions.plist"
  [[ -f "$background" ]] || die "DMG background not found: $background"
  [[ -f "$export_template" ]] || die "ExportOptions template not found: $export_template"
  [[ -f "$script_dir/dmg_background@2x.png" ]] || die "Retina DMG background not found: $script_dir/dmg_background@2x.png"

  require_cmd xcodebuild
  require_cmd xcrun
  require_cmd codesign
  require_cmd spctl
  require_cmd hdiutil
  require_cmd ditto
  require_cmd create-dmg "Install it with: brew install create-dmg"
  [[ -x "$PLISTBUDDY" ]] || die "PlistBuddy is not at $PLISTBUDDY"
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/geopeek-release.XXXXXX")
  trap cleanup EXIT
  cd "$WORK"

  local archive="$WORK/GeoPeek.xcarchive"
  local export_dir="$WORK/export"
  local export_plist="$WORK/ExportOptions.plist"
  local app="$export_dir/GeoPeek.app"
  local zip="$WORK/GeoPeek.zip"
  local staging="$WORK/dmg-staging"
  local dmg="$WORK/GeoPeek.dmg"
  local dmg_final="$root/GeoPeek-${VERSION}.dmg"

  echo "Archiving (clean Release, hardened runtime)..."
  # Extension targets set CODE_SIGN_IDENTITY[sdk=macosx*] to "-" for local
  # ad-hoc builds. A plain CODE_SIGN_IDENTITY on the command line overrides
  # that. xcodebuild does not treat SETTING[sdk=macosx*]=... as a conditional.
  xcodebuild clean archive \
    -project "$project" \
    -scheme GeoPeek \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive" \
    -derivedDataPath "$WORK/DerivedData" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    ENABLE_HARDENED_RUNTIME=YES

  cp "$export_template" "$export_plist"
  "$PLISTBUDDY" -c "Add :teamID string $DEVELOPMENT_TEAM" "$export_plist"

  echo "Exporting Developer ID archive..."
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_plist" \
    -allowProvisioningUpdates

  [[ -d "$app" ]] || die "export did not produce $app"
  assert_product "$app"

  local authority dmg_identity
  authority=$(signing_authority "$app") || die "could not read the signing authority of $app"
  [[ -n "$authority" ]] || die "could not read the signing authority of $app"
  case "$authority" in
    "Developer ID Application:"*"($DEVELOPMENT_TEAM)") ;;
    *) die "app is signed by '$authority', expected Developer ID Application for team $DEVELOPMENT_TEAM" ;;
  esac
  dmg_identity=${SIGN_IDENTITY:-$authority}

  echo "Notarizing the app..."
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"

  echo "Building the disk image..."
  mkdir -p "$staging"
  # ditto onto a path that does not exist. Copying into a directory that
  # already holds GeoPeek.app is how the 0.2.0 image nested a second app.
  [[ ! -e "$staging/GeoPeek.app" ]] || die "refusing to copy into an existing bundle at $staging/GeoPeek.app"
  ditto "$app" "$staging/GeoPeek.app"
  assert_bundle_layout "$staging/GeoPeek.app"

  # create-dmg sometimes exits non-zero after it has already written the image.
  # Keep that file either way, then fail if the command failed.
  local dmg_status
  set +e
  create-dmg \
    --volname "GeoPeek" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 80 \
    --icon "GeoPeek.app" 180 190 \
    --app-drop-link 480 190 \
    --background "$background" \
    --hide-extension "GeoPeek.app" \
    "$dmg" \
    "$staging"
  dmg_status=$?
  set -e
  if [[ -f "$dmg" ]]; then
    DMG_TMP=$dmg
  fi
  if [[ "$dmg_status" -ne 0 || ! -f "$dmg" ]]; then
    die "create-dmg failed (exit $dmg_status)"
  fi

  echo "Signing the disk image..."
  codesign --sign "$dmg_identity" --timestamp "$dmg"
  codesign --verify --verbose=2 "$dmg"
  local dmg_authority
  dmg_authority=$(signing_authority "$dmg")
  [[ "$dmg_authority" == "$authority" ]] || die "disk image signed by '$dmg_authority', app signed by '$authority'"

  echo "Notarizing the disk image..."
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"

  echo "Verifying the disk image..."
  MOUNT_POINT=$(mktemp -d "${TMPDIR:-/tmp}/geopeek-dmg-mount.XXXXXX")
  hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$MOUNT_POINT"
  local mounted="$MOUNT_POINT/GeoPeek.app"
  [[ -d "$mounted" ]] || die "mounted image has no GeoPeek.app"

  local copied="$WORK/from-dmg"
  mkdir -p "$copied"
  ditto "$mounted" "$copied/GeoPeek.app"
  hdiutil detach "$MOUNT_POINT" || hdiutil detach -force "$MOUNT_POINT"
  MOUNT_POINT=""

  assert_product "$copied/GeoPeek.app"
  spctl_exec "$copied/GeoPeek.app"
  spctl_dmg "$dmg"
  xcrun stapler validate "$copied/GeoPeek.app"
  xcrun stapler validate "$dmg"

  rm -f "$dmg_final"
  mv "$dmg" "$dmg_final"
  DMG_TMP=""
  echo ""
  echo "GeoPeek ${VERSION} (${BUILD})"
  echo "$dmg_final"
  du -h "$dmg_final" | awk '{ print $1 }'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
