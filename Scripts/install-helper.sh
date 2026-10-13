#!/bin/bash
# Builds iMCP Helper with your Apple Developer team and installs it.
# Apple doesn't allow HomeKit in Developer ID apps,
# so iMCP's release build leaves the helper out.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/install-helper.sh [--team TEAM_ID] [--bundle-id ID] [--destination DIR]

Builds iMCP Helper for Mac Catalyst, signs it with your team's
development certificate, and installs it so iMCP can enable Home.

  --team TEAM_ID     Apple Developer team ID.
                     Default: the team of your first Apple Development certificate.
  --bundle-id ID     Helper bundle ID. Default: local.imcp.helper.<team ID>.
  --destination DIR  Install directory. Default: /Applications.

Requires Xcode signed in to an Apple Developer account (Xcode > Settings > Accounts).
EOF
}

team=""
bundle_id=""
destination="/Applications"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team)
            team="${2:?--team needs a value}"
            shift 2
            ;;
        --bundle-id)
            bundle_id="${2:?--bundle-id needs a value}"
            shift 2
            ;;
        --destination)
            destination="${2:?--destination needs a value}"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

repo="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "$team" ]]; then
    certificate="$(security find-certificate -c "Apple Development" -p 2>/dev/null || true)"
    if [[ -z "$certificate" ]]; then
        echo "error: No Apple Development certificate found." >&2
        echo "Add your account in Xcode > Settings > Accounts, or pass --team TEAM_ID." >&2
        exit 1
    fi
    team="$(printf '%s\n' "$certificate" | openssl x509 -noout -subject -nameopt multiline |
        awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
    if [[ -z "$team" ]]; then
        echo "error: Couldn't read a team ID from your Apple Development certificate. Pass --team TEAM_ID." >&2
        exit 1
    fi
fi
if [[ -z "$bundle_id" ]]; then
    bundle_id="local.imcp.helper.$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]')"
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

build_helper() {
    xcodebuild -quiet -project "$repo/iMCP.xcodeproj" -scheme "iMCP Helper" \
        -configuration Release -destination "$1" \
        -derivedDataPath "$build_dir" -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" HELPER_BUNDLE_IDENTIFIER="$bundle_id" \
        build
}

echo "Building iMCP Helper for team $team as $bundle_id..."
if ! build_helper 'platform=macOS,variant=Mac Catalyst'; then
    # For a new bundle ID, automatic provisioning registers HomeKit
    # only for the iOS destination, so the first Catalyst build fails.
    # An iOS build registers it; then the Catalyst build can succeed.
    echo "Registering the HomeKit capability for $bundle_id, then retrying..."
    if ! build_helper 'generic/platform=iOS' || ! build_helper 'platform=macOS,variant=Mac Catalyst'; then
        echo "error: The build failed. Check that Xcode is signed in to team $team," >&2
        echo "that the team can use the HomeKit capability," >&2
        echo "and that the iOS platform is installed (Xcode > Settings > Components)." >&2
        exit 1
    fi
fi

app="$build_dir/Build/Products/Release-maccatalyst/iMCP Helper.app"
if ! codesign -d --entitlements - "$app" 2>/dev/null | grep -q "com.apple.developer.homekit"; then
    echo "error: The built helper has no HomeKit entitlement, so HomeKit would deny access." >&2
    echo "Check that team $team can provision HomeKit for $bundle_id." >&2
    exit 1
fi

target="$destination/iMCP Helper.app"
if pgrep -x "iMCP Helper" >/dev/null; then
    echo "Quitting the running iMCP Helper..."
    osascript -e 'quit app "iMCP Helper"' >/dev/null 2>&1 || pkill -x "iMCP Helper" || true
fi
mkdir -p "$destination"
rm -rf "$target"
ditto "$app" "$target"

echo "Installed $target."
echo "Next: open iMCP and turn on Home. iMCP finds the helper here;"
echo "if you installed it elsewhere, choose it in Settings > Services > Home."
