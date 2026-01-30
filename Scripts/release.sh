#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-iMCP}"
APP_BUNDLE="${APP_BUNDLE:-${APP_NAME}.app}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SCHEME="${SCHEME:-iMCP}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-platform=macOS}"
PROJECT_FILE="${PROJECT_FILE:-${APP_NAME}.xcodeproj/project.pbxproj}"
DIST_DIR="${DIST_DIR:-dist}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${DIST_DIR}/${APP_NAME}.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-${DIST_DIR}/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-${DIST_DIR}/export-options.plist}"
TEAM_ID="${TEAM_ID:-}"
SIGNING_CERTIFICATE="${SIGNING_CERTIFICATE:-Developer ID Application}"
BUNDLE_ID="${BUNDLE_ID:-}"
PROVISIONING_PROFILE_NAME="${PROVISIONING_PROFILE_NAME:-}"
PROVISIONING_PROFILE_UUID="${PROVISIONING_PROFILE_UUID:-}"

# Derived artifact names for notarization/release steps.
NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-notarize.zip"

print_usage() {
  cat <<'EOF'
Usage: Scripts/release.sh [command]

Commands:
  all         Build check, bump, archive, export, package, notarize, staple, commit/tag, release, upload (default)
  check       Quick release build check
  bump        Bump version/build numbers
  archive     Create an Xcode archive for direct distribution
  export      Export a Developer ID signed app from the archive
  profiles    List installed provisioning profiles
  package     Create the release zip from the app bundle
  notarize    Submit the app bundle for notarization
  staple      Staple the notarization ticket to the app bundle
  commit      Commit version bump and create release tag
  release     Create a GitHub release (no assets)
  upload      Upload the release asset to GitHub
  help        Show this help

Environment:
  APP_NAME          App name (default: iMCP)
  APP_BUNDLE        App bundle path (default: ${APP_NAME}.app)
  KEYCHAIN_PROFILE  Required for notarize
  VERSION           Required for bumping, commit, release, and upload
  BUILD_NUMBER      Optional; used when bumping build number
  SCHEME            Xcode scheme for build check (default: iMCP)
  CONFIGURATION     Build configuration for build check (default: Release)
  DESTINATION       Build destination for build check (default: platform=macOS)
  PROJECT_FILE      Xcode project file (default: ${APP_NAME}.xcodeproj/project.pbxproj)
  DIST_DIR          Output directory for artifacts (default: dist)
  ARCHIVE_PATH      Archive path (default: dist/${APP_NAME}.xcarchive)
  EXPORT_DIR        Export path for the signed app (default: dist/export)
  EXPORT_OPTIONS_PLIST Export options plist path (default: dist/export-options.plist)
  TEAM_ID           Team ID for Developer ID signing (optional)
  SIGNING_CERTIFICATE Signing certificate (default: Developer ID Application)
  BUNDLE_ID         Bundle identifier for export profiles (optional)
  PROVISIONING_PROFILE_NAME Provisioning profile name for export (optional)
  PROVISIONING_PROFILE_UUID Provisioning profile UUID for export (optional)
EOF
}

# If APP_BUNDLE isn't explicit, derive the built app path from Xcode settings.
resolve_app_bundle() {
  resolve_exported_app || true
  if [[ -d "${APP_BUNDLE}" ]]; then
    return 0
  fi

  local built_products_dir=""
  local full_product_name=""

  built_products_dir="$(xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" -showBuildSettings | awk -F ' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"
  full_product_name="$(xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" -showBuildSettings | awk -F ' = ' '/FULL_PRODUCT_NAME/ {print $2; exit}')"

  if [[ -n "${built_products_dir}" && -n "${full_product_name}" ]]; then
    local candidate="${built_products_dir}/${full_product_name}"
    if [[ -d "${candidate}" ]]; then
      APP_BUNDLE="${candidate}"
    fi
  fi
}

require_app_bundle() {
  resolve_app_bundle
  if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "Missing app bundle: ${APP_BUNDLE}" >&2
    exit 1
  fi
}

require_keychain_profile() {
  if [[ -z "${KEYCHAIN_PROFILE}" ]]; then
    echo "Missing keychain profile. Set KEYCHAIN_PROFILE." >&2
    exit 1
  fi
}

require_version() {
  if [[ -z "${VERSION}" ]]; then
    echo "VERSION is required for releases." >&2
    exit 1
  fi
}

require_clean_tree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree is dirty. Commit or stash changes first." >&2
    exit 1
  fi
}

ensure_dist_dir() {
  mkdir -p "${DIST_DIR}"
}

resolve_bundle_id() {
  if [[ -n "${BUNDLE_ID}" ]]; then
    return 0
  fi
  if [[ ! -f "${PROJECT_FILE}" ]]; then
    return 1
  fi
  while IFS= read -r line; do
    if [[ "${line}" == *"PRODUCT_BUNDLE_IDENTIFIER ="* && "${line}" != *"imcp-server"* ]]; then
      BUNDLE_ID="${line#*PRODUCT_BUNDLE_IDENTIFIER = }"
      BUNDLE_ID="${BUNDLE_ID%;}"
      return 0
    fi
  done < "${PROJECT_FILE}"
  return 1
}

list_profiles() {
  local profiles_dir
  local found_dir="0"
  local profile tmp_plist name uuid team weatherkit app_id
  local profiles_dirs=(
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  )
  resolve_bundle_id || true

  for profiles_dir in "${profiles_dirs[@]}"; do
    if [[ ! -d "${profiles_dir}" ]]; then
      continue
    fi
    found_dir="1"
    for profile in "${profiles_dir}"/*.mobileprovision "${profiles_dir}"/*.provisionprofile; do
      if [[ ! -f "${profile}" ]]; then
        continue
      fi
      tmp_plist="$(mktemp)"
      if ! security cms -D -i "${profile}" > "${tmp_plist}" 2>/dev/null; then
        rm -f "${tmp_plist}"
        continue
      fi
      name="$("/usr/libexec/PlistBuddy" -c "Print Name" "${tmp_plist}" 2>/dev/null || true)"
      uuid="$("/usr/libexec/PlistBuddy" -c "Print UUID" "${tmp_plist}" 2>/dev/null || true)"
      team="$("/usr/libexec/PlistBuddy" -c "Print TeamIdentifier:0" "${tmp_plist}" 2>/dev/null || true)"
      weatherkit="$("/usr/libexec/PlistBuddy" -c "Print Entitlements:com.apple.developer.weatherkit" "${tmp_plist}" 2>/dev/null || true)"
      app_id="$("/usr/libexec/PlistBuddy" -c "Print Entitlements:com.apple.application-identifier" "${tmp_plist}" 2>/dev/null || true)"
      rm -f "${tmp_plist}"
      if [[ -n "${BUNDLE_ID}" && -n "${app_id}" ]]; then
        if [[ "${app_id}" != *".${BUNDLE_ID}" && "${app_id}" != "${BUNDLE_ID}" ]]; then
          continue
        fi
      fi
      printf '%s\n' "Name: ${name}"
      printf '%s\n' "UUID: ${uuid}"
      printf '%s\n' "Team: ${team}"
      if [[ -n "${app_id}" ]]; then
        printf '%s\n' "App ID: ${app_id}"
      fi
      if [[ -n "${weatherkit}" ]]; then
        printf '%s\n' "WeatherKit: ${weatherkit}"
      fi
      printf '%s\n\n' "File: ${profile}"
    done
  done

  if [[ "${found_dir}" != "1" ]]; then
    echo "No provisioning profiles directory found at expected locations:" >&2
    echo "  ${profiles_dirs[0]}" >&2
    echo "  ${profiles_dirs[1]}" >&2
    exit 1
  fi
}

resolve_exported_app() {
  local candidate
  for candidate in "${EXPORT_DIR}"/*.app "${EXPORT_DIR}"/Applications/*.app "${EXPORT_DIR}"/Products/Applications/*.app; do
    if [[ -d "${candidate}" ]]; then
      APP_BUNDLE="${candidate}"
      return 0
    fi
  done
  return 1
}

release_zip() {
  require_version
  printf '%s/%s-%s.zip' "${DIST_DIR}" "${APP_NAME}" "${VERSION}"
}

cleanup() {
  rm -f "${NOTARY_ZIP}"
}

trap cleanup EXIT

bump_version() {
  require_version
  if [[ ! -f "${PROJECT_FILE}" ]]; then
    echo "Missing project file: ${PROJECT_FILE}" >&2
    exit 1
  fi
  local resolved_build_number="${BUILD_NUMBER}"
  if [[ -z "${resolved_build_number}" ]]; then
    # Find the current build number and increment it if not provided.
    resolved_build_number="0"
    while IFS= read -r line; do
      if [[ "${line}" =~ CURRENT_PROJECT_VERSION\ =\ ([0-9]+)\; ]]; then
        resolved_build_number="${BASH_REMATCH[1]}"
        break
      fi
    done < "${PROJECT_FILE}"
    resolved_build_number="$((resolved_build_number + 1))"
  fi

  echo "Setting MARKETING_VERSION to ${VERSION}"
  echo "Setting CURRENT_PROJECT_VERSION to ${resolved_build_number}"
  # Replace both version fields in the project file without agvtool.
  local tmp_file
  tmp_file="$(mktemp)"
  while IFS= read -r line; do
    if [[ "${line}" == *"MARKETING_VERSION ="* ]]; then
      printf '%s\n' "${line%%MARKETING_VERSION = *}MARKETING_VERSION = ${VERSION};" >> "${tmp_file}"
    elif [[ "${line}" == *"CURRENT_PROJECT_VERSION ="* ]]; then
      printf '%s\n' "${line%%CURRENT_PROJECT_VERSION = *}CURRENT_PROJECT_VERSION = ${resolved_build_number};" >> "${tmp_file}"
    else
      printf '%s\n' "${line}" >> "${tmp_file}"
    fi
  done < "${PROJECT_FILE}"
  mv "${tmp_file}" "${PROJECT_FILE}"
}

build_zip() {
  local source_bundle="$1"
  local output_zip="$2"
  ensure_dist_dir
  echo "Creating zip: ${output_zip}"
  ditto -c -k --keepParent "${source_bundle}" "${output_zip}"
}

build_check() {
  echo "Checking release build (scheme: ${SCHEME}, configuration: ${CONFIGURATION})"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" build
  resolve_app_bundle
}

archive_app() {
  ensure_dist_dir
  echo "Archiving app to ${ARCHIVE_PATH}"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "generic/platform=macOS" archive -archivePath "${ARCHIVE_PATH}"
}

write_export_options() {
  ensure_dist_dir
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>${SIGNING_CERTIFICATE}</string>
EOF
  local profile_value=""
  if [[ -n "${PROVISIONING_PROFILE_UUID}" ]]; then
    profile_value="${PROVISIONING_PROFILE_UUID}"
  elif [[ -n "${PROVISIONING_PROFILE_NAME}" ]]; then
    profile_value="${PROVISIONING_PROFILE_NAME}"
  fi
  if [[ -n "${profile_value}" ]]; then
    if ! resolve_bundle_id; then
      echo "BUNDLE_ID is required when using provisioning profiles." >&2
      exit 1
    fi
    cat >> "${tmp_file}" <<EOF
  <key>provisioningProfiles</key>
  <dict>
    <key>${BUNDLE_ID}</key>
    <string>${profile_value}</string>
  </dict>
EOF
  fi
  if [[ -n "${TEAM_ID}" ]]; then
    cat >> "${tmp_file}" <<EOF
  <key>teamID</key>
  <string>${TEAM_ID}</string>
EOF
  fi
  cat >> "${tmp_file}" <<'EOF'
</dict>
</plist>
EOF
  mv "${tmp_file}" "${EXPORT_OPTIONS_PLIST}"
}

export_app() {
  write_export_options
  echo "Exporting Developer ID app to ${EXPORT_DIR}"
  xcodebuild -quiet -exportArchive -archivePath "${ARCHIVE_PATH}" -exportPath "${EXPORT_DIR}" -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"
  resolve_app_bundle
}

notarize() {
  require_app_bundle
  require_keychain_profile
  ensure_dist_dir
  echo "Zipping for notarization: ${NOTARY_ZIP}"
  ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"
  echo "Submitting to notarization"
  xcrun notarytool submit "${NOTARY_ZIP}" --wait --keychain-profile="${KEYCHAIN_PROFILE}"
}

staple() {
  require_app_bundle
  echo "Stapling notarization ticket"
  xcrun stapler staple "${APP_BUNDLE}"
}

package_release() {
  require_app_bundle
  local release_zip_path
  release_zip_path="$(release_zip)"
  build_zip "${APP_BUNDLE}" "${release_zip_path}"
  shasum -a 256 "${release_zip_path}" > "${release_zip_path}.sha256"
  echo "Done: ${release_zip_path}"
}

validate_staple() {
  require_app_bundle
  echo "Validating stapled ticket"
  xcrun stapler validate "${APP_BUNDLE}"
}

commit_and_tag() {
  require_version
  local release_zip_path
  release_zip_path="$(release_zip)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  # Ensure the stapled build exists before tagging a release.
  validate_staple
  if git rev-parse --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then
    echo "Tag already exists: ${VERSION}" >&2
    exit 1
  fi
  echo "Committing version bump"
  git add -A
  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -m "Release ${VERSION}"
  fi
  echo "Tagging release ${VERSION}"
  git tag -a "${VERSION}" -m "Release ${VERSION}"
}

create_release() {
  require_version
  echo "Creating GitHub release ${VERSION}"
  gh release create "${VERSION}" --generate-notes
}

upload_asset() {
  require_version
  local release_zip_path
  release_zip_path="$(release_zip)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  echo "Uploading release asset ${release_zip_path}"
  gh release upload "${VERSION}" "${release_zip_path}" --clobber
  gh release view --web "${VERSION}"
}

all() {
  # Full release flow with strict gating at each step.
  build_check
  require_clean_tree
  bump_version
  archive_app
  export_app
  package_release
  notarize
  staple
  commit_and_tag
  create_release
  upload_asset
}

release() {
  create_release
}

upload() {
  upload_asset
}

COMMAND="${1:-all}"
case "${COMMAND}" in
  all)
    all
    ;;
  check)
    build_check
    ;;
  bump)
    bump_version
    ;;
  archive)
    archive_app
    ;;
  export)
    export_app
    ;;
  profiles)
    list_profiles
    ;;
  package)
    package_release
    ;;
  notarize)
    notarize
    ;;
  staple)
    staple
    ;;
  commit)
    commit_and_tag
    ;;
  release)
    release
    ;;
  upload)
    upload
    ;;
  help|-h|--help)
    print_usage
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    print_usage >&2
    exit 1
    ;;
esac
