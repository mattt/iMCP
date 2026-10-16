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
                     Default: your team, if your keychain has Apple Development
                     identities for exactly one team; otherwise required.
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

# Prints "TEAM_ID<tab>organization" for each team
# with a valid Apple Development signing identity.
development_teams() {
    local hashes pem="" line
    hashes="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { printf "%s ", $2 }')"
    [[ -n "$hashes" ]] || return 0
    security find-certificate -a -Z -c "Apple Development" -p 2>/dev/null |
        awk -v hashes="$hashes" '
            BEGIN { n = split(hashes, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
            /^SHA-1 hash:/ { keep = ($3 in want); next }
            keep { print }
        ' |
        while IFS= read -r line; do
            pem="$pem$line"$'\n'
            if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
                printf '%s' "$pem" | openssl x509 -noout -subject -nameopt multiline |
                    awk -F' = ' '
                        /organizationalUnitName/ { team = $2 }
                        /organizationName/ { name = $2 }
                        END { if (team != "") print team "\t" name }
                    '
                pem=""
            fi
        done | sort -u
}

if [[ -z "$team" ]]; then
    teams="$(development_teams)"
    if [[ -z "$teams" ]]; then
        echo "error: No valid Apple Development signing identity found." >&2
        echo "Add your account in Xcode > Settings > Accounts, or pass --team TEAM_ID." >&2
        exit 1
    fi
    if [[ "$(printf '%s\n' "$teams" | wc -l | tr -d ' ')" != 1 ]]; then
        echo "error: Your keychain has Apple Development identities for more than one team:" >&2
        printf '%s\n' "$teams" | awk -F'\t' '{ printf "  %s  %s\n", $1, $2 }' >&2
        echo "Choose one with --team TEAM_ID." >&2
        exit 1
    fi
    team="${teams%%$'\t'*}"
fi
if [[ -z "$bundle_id" ]]; then
    bundle_id="local.imcp.helper.$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]')"
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
# xcodebuild handles ^C itself and exits with an error,
# so without this trap the script would go on to the next build.
trap 'echo "Interrupted." >&2; exit 130' INT TERM

build_helper() {
    xcodebuild -quiet -project "$repo/iMCP.xcodeproj" -scheme "iMCP Helper" \
        -configuration Release -destination "$1" \
        -derivedDataPath "$build_dir" -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" HELPER_BUNDLE_IDENTIFIER="$bundle_id" \
        build
}

echo "Building iMCP Helper for team $team as $bundle_id..."
first_log="$build_dir/catalyst.log"
if ! build_helper 'platform=macOS,variant=Mac Catalyst' >"$first_log" 2>&1; then
    if ! grep -q "Entitlement com.apple.developer.homekit not found" "$first_log"; then
        cat "$first_log" >&2
        echo "error: The build failed. Check that Xcode is signed in to team $team." >&2
        exit 1
    fi
    # For a new bundle ID, automatic provisioning registers HomeKit
    # only for the iOS destination, so the first Catalyst build fails.
    # An iOS build registers it; then the Catalyst build can succeed.
    echo "Registering the HomeKit capability for $bundle_id (first build for this bundle ID)..."
    if ! build_helper 'generic/platform=iOS' || ! build_helper 'platform=macOS,variant=Mac Catalyst'; then
        echo "error: The build failed. Check that team $team can use the HomeKit capability" >&2
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
if [[ "$target" == "/Applications/iMCP Helper.app" ]]; then
    echo "Next: open iMCP and turn on Home. iMCP finds the helper here."
else
    echo "Next: open iMCP and turn on Home, then choose $target when iMCP asks."
fi
