#!/bin/bash
# Xcode cannot select a Catalyst variant for a native macOS target dependency.
set -euo pipefail

: "${SRCROOT:?Run this script from the iMCP Xcode build phase.}"
: "${TARGET_BUILD_DIR:?Missing Xcode product directory.}"
: "${WRAPPER_NAME:?Missing Xcode app wrapper name.}"
: "${CONFIGURATION:?Missing Xcode configuration.}"
: "${PROJECT_TEMP_DIR:?Missing Xcode intermediates directory.}"

helper_derived_data="$PROJECT_TEMP_DIR/HomeHelperDerivedData"
helper_signing="${HOME_HELPER_CODE_SIGNING_ALLOWED:-YES}"

# Keep the nested build's environment, products, and build database separate.
# Inherited Xcode settings otherwise rename package products after the native app.
env -i PATH="$PATH" HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
    TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
    xcodebuild -quiet -project "$SRCROOT/iMCP.xcodeproj" \
    -scheme "iMCP Home" -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$helper_derived_data" \
    CODE_SIGNING_ALLOWED="$helper_signing" CODE_SIGNING_REQUIRED="$helper_signing" \
    build

helper_product="$helper_derived_data/Build/Products/$CONFIGURATION-maccatalyst/iMCP Home.app"
helper_destination="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/iMCP Home.app"
if [[ ! -d "$helper_product/Contents/MacOS" ]]; then
    echo 'error: The Home helper build did not produce a Catalyst app.' >&2
    exit 1
fi
mkdir -p "$(dirname "$helper_destination")"
# ditto preserves the helper's development signature when the native Debug app is unsigned.
# Remove stale files if the nested app's contents changed between builds.
rm -rf "$helper_destination"
ditto "$helper_product" "$helper_destination"
