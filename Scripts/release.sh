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

NOTARY_ZIP="${APP_BUNDLE}.zip"
RELEASE_ZIP="${APP_NAME}.zip"

print_usage() {
  cat <<'EOF'
Usage: Scripts/release.sh [command]

Commands:
  all         Build check, bump, package, notarize, staple, commit/tag, release, upload (default)
  check       Quick release build check
  bump        Bump version/build numbers
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
EOF
}

require_app_bundle() {
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

cleanup() {
  rm -f "${NOTARY_ZIP}"
}

trap cleanup EXIT

bump_version() {
  require_version
  echo "Bumping version to ${VERSION}"
  agvtool new-marketing-version "${VERSION}"

  if [[ -n "${BUILD_NUMBER}" ]]; then
    echo "Setting build number to ${BUILD_NUMBER}"
    agvtool new-version -all "${BUILD_NUMBER}"
  else
    echo "Bumping build number"
    agvtool next-version -all
  fi
}

build_zip() {
  local source_bundle="$1"
  local output_zip="$2"
  echo "Creating zip: ${output_zip}"
  ditto -c -k --keepParent "${source_bundle}" "${output_zip}"
}

build_check() {
  echo "Checking release build (scheme: ${SCHEME}, configuration: ${CONFIGURATION})"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" build
}

notarize() {
  require_app_bundle
  require_keychain_profile
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
  build_zip "${APP_BUNDLE}" "${RELEASE_ZIP}"
  echo "Done: ${RELEASE_ZIP}"
}

validate_staple() {
  require_app_bundle
  echo "Validating stapled ticket"
  xcrun stapler validate "${APP_BUNDLE}"
}

commit_and_tag() {
  require_version
  if [[ ! -f "${RELEASE_ZIP}" ]]; then
    echo "Missing release asset: ${RELEASE_ZIP}" >&2
    exit 1
  fi
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
  if [[ ! -f "${RELEASE_ZIP}" ]]; then
    echo "Missing release asset: ${RELEASE_ZIP}" >&2
    exit 1
  fi
  echo "Uploading release asset ${RELEASE_ZIP}"
  gh release upload "${VERSION}" "${RELEASE_ZIP}" --clobber
  gh release view --web "${VERSION}"
}

all() {
  build_check
  require_clean_tree
  bump_version
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
