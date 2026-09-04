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
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARY_KEY_FILE="${NOTARY_KEY_FILE:-}"
SPARKLE_BIN="${SPARKLE_BIN:-}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
APPCAST_DIR="${APPCAST_DIR:-${DIST_DIR}/appcast}"
APPCAST_LINK="${APPCAST_LINK:-https://imcp.app}"
RELEASE_DOWNLOAD_BASE="${RELEASE_DOWNLOAD_BASE:-https://github.com/mattt/iMCP/releases/download}"
DRY_RUN="${DRY_RUN:-}"

# Derived artifact names for notarization/release steps.
NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-notarize.zip"

print_usage() {
  cat <<'EOF'
Usage: Scripts/release.sh [command]

Commands:
  all         Build check, bump, archive, export, notarize, staple, package, commit/tag, push tag (default); the Release workflow publishes
  check       Quick release build check
  bump        Bump version/build numbers
  archive     Create an Xcode archive for direct distribution
  export      Export a Developer ID signed app from the archive
  profiles    List installed provisioning profiles
  package     Create the release zip from the app bundle
  notarize    Submit the app bundle for notarization
  staple      Staple the notarization ticket to the app bundle
  commit      Commit version bump and create release tag
  appcast     Generate and validate the signed Sparkle appcast
  release     Create a draft GitHub release for the tag at HEAD (no assets)
  upload      Upload the release asset to the draft release
  upload-appcast Upload the appcast to the draft release
  publish     Publish the draft release and mark it latest
  help        Show this help

Environment:
  APP_NAME          App name (default: iMCP)
  APP_BUNDLE        App bundle path (default: ${APP_NAME}.app)
  KEYCHAIN_PROFILE  notarytool keychain profile (notarize; or set the NOTARY_* keys)
  NOTARY_KEY_ID     App Store Connect API key ID (notarize, alternative to KEYCHAIN_PROFILE)
  NOTARY_ISSUER_ID  App Store Connect API issuer ID (with NOTARY_KEY_ID)
  NOTARY_KEY_FILE   Path to the App Store Connect API .p8 key (with NOTARY_KEY_ID)
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
  SPARKLE_BIN       Directory containing Sparkle's generate_appcast (default: found in DerivedData or PATH)
  SPARKLE_PRIVATE_KEY_FILE Path to the Sparkle EdDSA private key (default: the login keychain)
  SPARKLE_PUBLIC_KEY Expected SUPublicEDKey; the appcast step fails if the app carries a different key (optional)
  APPCAST_DIR       Working directory for the appcast (default: dist/appcast)
  APPCAST_LINK      Link element for appcast items (default: https://imcp.app)
  RELEASE_DOWNLOAD_BASE Base URL for release assets (default: https://github.com/mattt/iMCP/releases/download)
  DRY_RUN           If set, skip creating the GitHub release and uploading assets
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

# notarytool accepts either a stored keychain profile
# or an App Store Connect API key passed explicitly.
# The API key form is what CI uses.
notary_credential_args() {
  if [[ -n "${NOTARY_KEY_ID}" || -n "${NOTARY_ISSUER_ID}" || -n "${NOTARY_KEY_FILE}" ]]; then
    if [[ -z "${NOTARY_KEY_ID}" || -z "${NOTARY_ISSUER_ID}" || -z "${NOTARY_KEY_FILE}" ]]; then
      echo "NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_KEY_FILE must be set together." >&2
      exit 1
    fi
    if [[ ! -f "${NOTARY_KEY_FILE}" ]]; then
      echo "Missing notary key file: ${NOTARY_KEY_FILE}" >&2
      exit 1
    fi
    printf '%s\n' "--key" "${NOTARY_KEY_FILE}" "--key-id" "${NOTARY_KEY_ID}" "--issuer" "${NOTARY_ISSUER_ID}"
    return 0
  fi
  if [[ -z "${KEYCHAIN_PROFILE}" ]]; then
    echo "Missing notarization credentials. Set KEYCHAIN_PROFILE, or NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_KEY_FILE." >&2
    exit 1
  fi
  printf '%s\n' "--keychain-profile" "${KEYCHAIN_PROFILE}"
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

# The project's Release configuration signs the app with an Apple Development identity,
# which a release machine may not have.
# When a Developer ID certificate is configured, archive with it directly;
# export re-signs with the provisioning profile afterwards.
archive_signing_args() {
  if [[ -z "${TEAM_ID}" ]]; then
    return 0
  fi
  printf '%s\n' \
    "CODE_SIGN_STYLE=Manual" \
    "CODE_SIGN_IDENTITY=${SIGNING_CERTIFICATE}" \
    "DEVELOPMENT_TEAM=${TEAM_ID}"
  # The app's WeatherKit entitlement needs its provisioning profile at archive time,
  # but a command-line override applies to every target,
  # and the embedded CLI has a different bundle identifier.
  # Route the profile through a setting keyed by product name
  # so only the app target resolves to it.
  local profile_value=""
  if [[ -n "${PROVISIONING_PROFILE_UUID}" ]]; then
    profile_value="${PROVISIONING_PROFILE_UUID}"
  elif [[ -n "${PROVISIONING_PROFILE_NAME}" ]]; then
    profile_value="${PROVISIONING_PROFILE_NAME}"
  fi
  if [[ -n "${profile_value}" ]]; then
    printf '%s\n' \
      'PROVISIONING_PROFILE_SPECIFIER=$(RELEASE_PROFILE_FOR_$(PRODUCT_NAME))' \
      "RELEASE_PROFILE_FOR_${APP_NAME}=${profile_value}"
  fi
}

archive_app() {
  ensure_dist_dir
  local signing_args=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && signing_args+=("${line}")
  done <<< "$(archive_signing_args)"
  echo "Archiving app to ${ARCHIVE_PATH}"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "generic/platform=macOS" archive -archivePath "${ARCHIVE_PATH}" ${signing_args[@]+"${signing_args[@]}"}
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
  # Capture first so a validation failure in the helper stops the script;
  # a process substitution would swallow its exit status.
  local credential_output
  credential_output="$(notary_credential_args)"
  local credential_args=()
  while IFS= read -r line; do
    credential_args+=("${line}")
  done <<< "${credential_output}"
  ensure_dist_dir
  echo "Zipping for notarization: ${NOTARY_ZIP}"
  ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"
  echo "Submitting to notarization"
  xcrun notarytool submit "${NOTARY_ZIP}" --wait "${credential_args[@]}"
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

push_tags() {
  require_version
  if ! git rev-parse --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then
    echo "Missing tag: ${VERSION}" >&2
    exit 1
  fi
  local response=""
  read -r -p "Push tag ${VERSION} to origin? [y/N] " response
  if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
    echo "Tag push cancelled."
    exit 1
  fi
  # Push only this release's tag: every pushed version tag starts a release.
  git push origin "refs/tags/${VERSION}"
}

# The release tag must exist and point at the commit being released,
# or gh would mint a tag on the default branch that doesn't match the binary.
require_release_tag() {
  require_version
  local tag_commit head_commit
  tag_commit="$(git rev-list -n 1 "refs/tags/${VERSION}" 2>/dev/null || true)"
  if [[ -z "${tag_commit}" ]]; then
    echo "Missing tag: ${VERSION}. Tag the release commit before publishing." >&2
    exit 1
  fi
  head_commit="$(git rev-parse HEAD)"
  if [[ "${tag_commit}" != "${head_commit}" ]]; then
    echo "Tag ${VERSION} points at ${tag_commit}, but HEAD is ${head_commit}." >&2
    exit 1
  fi
  # The remote tag is what the release records, so it must exist and match too.
  local remote_commit
  remote_commit="$(git ls-remote --tags origin "refs/tags/${VERSION}^{}" "refs/tags/${VERSION}" 2>/dev/null | awk '{print $1}' | tail -n 1 || true)"
  if [[ -z "${remote_commit}" ]]; then
    echo "Tag ${VERSION} hasn't been pushed to origin." >&2
    exit 1
  fi
  if [[ "${remote_commit}" != "${tag_commit}" && "${remote_commit}" != "$(git rev-parse "refs/tags/${VERSION}")" ]]; then
    echo "Tag ${VERSION} on origin (${remote_commit}) doesn't match the local tag (${tag_commit})." >&2
    exit 1
  fi
}

# The release starts as a draft so a failure partway through
# never leaves a half-populated release as the latest one.
create_release() {
  require_version
  if [[ -n "${DRY_RUN}" ]]; then
    echo "Dry run: would create draft GitHub release ${VERSION}"
    return 0
  fi
  require_release_tag
  # A rerun after a partial failure finds the draft from the last attempt;
  # reuse it so the --clobber uploads can repair it.
  local is_draft
  if is_draft="$(gh release view "${VERSION}" --json isDraft --jq '.isDraft' 2>/dev/null)"; then
    if [[ "${is_draft}" == "true" ]]; then
      echo "Reusing existing draft release ${VERSION}"
      return 0
    fi
    echo "Release ${VERSION} is already published." >&2
    exit 1
  fi
  echo "Creating draft GitHub release ${VERSION}"
  gh release create "${VERSION}" --draft --generate-notes --verify-tag
}

publish_release() {
  require_version
  if [[ -n "${DRY_RUN}" ]]; then
    echo "Dry run: would publish GitHub release ${VERSION}"
    return 0
  fi
  echo "Publishing GitHub release ${VERSION}"
  gh release edit "${VERSION}" --draft=false --latest
  if [[ -t 1 && -z "${CI:-}" ]]; then
    gh release view --web "${VERSION}"
  fi
}

upload_asset() {
  require_version
  local release_zip_path
  release_zip_path="$(release_zip)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  local upload_path="${DIST_DIR}/${APP_NAME}.zip"
  if [[ "${release_zip_path}" != "${upload_path}" ]]; then
    cp -f "${release_zip_path}" "${upload_path}"
  fi
  if [[ -n "${DRY_RUN}" ]]; then
    echo "Dry run: would upload ${upload_path} to release ${VERSION}"
    return 0
  fi
  echo "Uploading release asset ${upload_path}"
  gh release upload "${VERSION}" "${upload_path}" --clobber
}

# Sparkle ships generate_appcast inside its SwiftPM artifact,
# so look there before falling back to PATH.
resolve_sparkle_bin() {
  if [[ -n "${SPARKLE_BIN}" ]]; then
    if [[ ! -x "${SPARKLE_BIN}/generate_appcast" ]]; then
      echo "generate_appcast not found in SPARKLE_BIN: ${SPARKLE_BIN}" >&2
      exit 1
    fi
    return 0
  fi
  local candidate
  candidate="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -type f -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    SPARKLE_BIN="$(dirname "${candidate}")"
    return 0
  fi
  if command -v generate_appcast >/dev/null 2>&1; then
    SPARKLE_BIN="$(dirname "$(command -v generate_appcast)")"
    return 0
  fi
  echo "Sparkle's generate_appcast was not found. Set SPARKLE_BIN to its directory." >&2
  exit 1
}

# The app must embed the public half of the key that signs the appcast,
# or Sparkle refuses the update on the client.
verify_sparkle_public_key() {
  if [[ -z "${SPARKLE_PUBLIC_KEY}" ]]; then
    return 0
  fi
  require_app_bundle
  local embedded_key
  embedded_key="$("/usr/libexec/PlistBuddy" -c "Print SUPublicEDKey" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${embedded_key}" != "${SPARKLE_PUBLIC_KEY}" ]]; then
    echo "SUPublicEDKey in ${APP_BUNDLE} does not match SPARKLE_PUBLIC_KEY." >&2
    echo "  app:      ${embedded_key:-<missing>}" >&2
    echo "  expected: ${SPARKLE_PUBLIC_KEY}" >&2
    exit 1
  fi
}

build_appcast() {
  require_version
  resolve_sparkle_bin
  verify_sparkle_public_key
  local release_zip_path
  release_zip_path="$(release_zip)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  # generate_appcast reads every archive in its directory,
  # so give it a directory holding only this release,
  # named as the asset is named on GitHub.
  rm -rf "${APPCAST_DIR}"
  mkdir -p "${APPCAST_DIR}"
  cp -f "${release_zip_path}" "${APPCAST_DIR}/${APP_NAME}.zip"
  local key_args=()
  if [[ -n "${SPARKLE_PRIVATE_KEY_FILE}" ]]; then
    if [[ ! -f "${SPARKLE_PRIVATE_KEY_FILE}" ]]; then
      echo "Missing Sparkle private key file: ${SPARKLE_PRIVATE_KEY_FILE}" >&2
      exit 1
    fi
    key_args=(--ed-key-file "${SPARKLE_PRIVATE_KEY_FILE}")
  fi
  echo "Generating appcast in ${APPCAST_DIR}"
  # macOS ships bash 3.2, where an empty array trips set -u.
  "${SPARKLE_BIN}/generate_appcast" \
    ${key_args[@]+"${key_args[@]}"} \
    --download-url-prefix "${RELEASE_DOWNLOAD_BASE}/${VERSION}/" \
    --link "${APPCAST_LINK}" \
    "${APPCAST_DIR}"
  local appcast_path="${APPCAST_DIR}/appcast.xml"
  if [[ ! -f "${appcast_path}" ]]; then
    echo "generate_appcast did not write ${appcast_path}" >&2
    exit 1
  fi
  # generate_appcast leaves the signature off silently
  # when the app's SUPublicEDKey doesn't match the signing key.
  if ! grep -q 'sparkle:edSignature="' "${appcast_path}"; then
    echo "Appcast item is unsigned. Check that SUPublicEDKey in the app matches the Sparkle private key." >&2
    exit 1
  fi
  echo "Done: ${appcast_path}"
}

upload_appcast() {
  require_version
  local appcast_path="${APPCAST_DIR}/appcast.xml"
  if [[ ! -f "${appcast_path}" ]]; then
    echo "Missing appcast: ${appcast_path}" >&2
    exit 1
  fi
  if [[ -n "${DRY_RUN}" ]]; then
    echo "Dry run: would upload ${appcast_path} to release ${VERSION}"
    return 0
  fi
  echo "Uploading appcast to release ${VERSION}"
  gh release upload "${VERSION}" "${appcast_path}" --clobber
}

all() {
  # Full release flow with strict gating at each step.
  build_check
  require_clean_tree
  bump_version
  archive_app
  export_app
  notarize
  staple
  package_release
  commit_and_tag
  push_tags
  # The Release workflow publishes from the pushed tag.
  # Publishing here too would race it for the same release.
  echo "Tag ${VERSION} pushed. The Release workflow builds and publishes it."
  echo "Use the appcast, release, upload, upload-appcast, and publish commands only if it can't."
}

appcast() {
  build_appcast
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
  push-tags)
    push_tags
    ;;
  release)
    release
    ;;
  upload)
    upload
    ;;
  appcast)
    appcast
    ;;
  upload-appcast)
    upload_appcast
    ;;
  publish)
    publish_release
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
