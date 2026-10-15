#!/bin/bash
# Builds iMCP for iOS with your Apple Developer team and installs it on an iPhone or iPad.
# HealthKit, AlarmKit, and FinanceKit data stays on the device,
# so iMCP reaches it through this app.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/install-ios.sh [--team TEAM_ID] [--bundle-id ID] [--device NAME_OR_ID] [--finance]

Builds iMCP for iOS, signs it with your team's development
certificate, and installs it on a connected or paired iPhone or iPad.

  --team TEAM_ID      Apple Developer team ID.
                      Default: your team, if your keychain has Apple Development
                      identities for exactly one team; otherwise required.
  --bundle-id ID      App bundle ID. Default: local.imcp.ios.<team ID>.
  --device NAME_OR_ID iPhone or iPad to install on, by name, UDID, or identifier.
                      Default: the only available iPhone or iPad.
  --finance           Include the FinanceKit entitlement. Apple grants it only
                      after review, so most teams can't provision it.
  --build-only        Build and check the app without installing it.

Requires Xcode signed in to a paid Apple Developer account
(Xcode > Settings > Accounts), an iPhone or iPad with iOS 26 or later
in Developer Mode, and the device registered to your team.
EOF
}

team=""
bundle_id=""
device=""
finance=NO
install=YES
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
        --device)
            device="${2:?--device needs a value}"
            shift 2
            ;;
        --finance)
            finance=YES
            shift
            ;;
        --build-only)
            install=NO
            shift
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
    bundle_id="local.imcp.ios.$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]')"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
# xcodebuild handles ^C itself and exits with an error,
# so without this trap the script would go on to the next step.
trap 'echo "Interrupted." >&2; exit 130' INT TERM

# Prints "identifier<tab>name<tab>UDID" for each iPhone and iPad that devicectl knows.
list_iphones() {
    local json="$work_dir/devices.json"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || return 0
    /usr/bin/python3 -I - "$json" <<'PY'
import json, sys
for device in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    if hardware.get("deviceType") not in ("iPhone", "iPad") or hardware.get("reality") == "simulated":
        continue
    name = device.get("deviceProperties", {}).get("name", "")
    print(f"{device.get('identifier', '')}\t{name}\t{hardware.get('udid', '')}")
PY
}

if [[ "$install" == YES ]]; then
    iphones="$(list_iphones)"
    if [[ -z "$device" ]]; then
        if [[ -z "$iphones" ]]; then
            echo "error: No iPhone or iPad is available. Connect one with a cable or pair it in Xcode" >&2
            echo "(Window > Devices and Simulators), or pass --build-only." >&2
            exit 1
        fi
        if [[ "$(printf '%s\n' "$iphones" | wc -l | tr -d ' ')" != 1 ]]; then
            echo "error: More than one iPhone or iPad is available:" >&2
            printf '%s\n' "$iphones" | awk -F'\t' '{ printf "  %s  (%s)\n", $2, $3 }' >&2
            echo "Choose one with --device NAME_OR_ID." >&2
            exit 1
        fi
        device="$(printf '%s' "$iphones" | cut -f1)"
    fi
fi

echo "Building iMCP for iOS for team $team as $bundle_id..."
log="$work_dir/build.log"
if ! xcodebuild -quiet -project "$repo/iMCP.xcodeproj" -scheme "iMCP iOS" \
    -configuration Release -destination "generic/platform=iOS" \
    -derivedDataPath "$work_dir/build" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" \
    IOS_BUNDLE_IDENTIFIER="$bundle_id" IOS_FINANCEKIT="$finance" \
    build >"$log" 2>&1; then
    cat "$log" >&2
    if grep -q "financekit" "$log"; then
        echo "error: Team $team can't provision FinanceKit. Build without --finance;" >&2
        echo "Health and Alarms work without it." >&2
    elif grep -qi "no devices\|register.*device" "$log"; then
        echo "error: Team $team has no registered iPhone or iPad. Connect the device once and rerun," >&2
        echo "or register it at developer.apple.com." >&2
    else
        echo "error: The build failed. Check that Xcode is signed in to team $team," >&2
        echo "that the account is a paid membership, and that the iOS platform is installed" >&2
        echo "(Xcode > Settings > Components)." >&2
    fi
    exit 1
fi

app="$work_dir/build/Build/Products/Release-iphoneos/iMCP iOS.app"
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
for entitlement in com.apple.developer.healthkit com.apple.security.application-groups; do
    if ! grep -q "$entitlement" <<<"$entitlements"; then
        echo "error: The built app has no $entitlement entitlement," >&2
        echo "so iOS would deny access. Check that team $team can provision it for $bundle_id." >&2
        exit 1
    fi
done
if [[ "$finance" == YES ]] && ! grep -q "com.apple.developer.financekit" <<<"$entitlements"; then
    echo "error: The built app has no FinanceKit entitlement. Build without --finance." >&2
    exit 1
fi

# Development profiles expire; iOS refuses to launch the app after that.
expiration="$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null |
    plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)"
if [[ -n "$expiration" ]]; then
    expires_at="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expiration" +%s 2>/dev/null || echo 0)"
    if ((expires_at > 0 && expires_at <= $(date +%s))); then
        echo "error: The provisioning profile expired on $expiration. Rerun this script to renew it." >&2
        exit 1
    fi
fi

if [[ "$install" == NO ]]; then
    mkdir -p "$repo/build"
    rm -rf "$repo/build/iMCP iOS.app"
    ditto "$app" "$repo/build/iMCP iOS.app"
    echo "Built $repo/build/iMCP iOS.app."
    exit 0
fi

echo "Installing on $device..."
if ! xcrun devicectl device install app --device "$device" "$app" >"$log" 2>&1; then
    cat "$log" >&2
    echo "error: Installation failed. Unlock the device, turn on Developer Mode" >&2
    echo "(Settings > Privacy & Security > Developer Mode), and trust this Mac, then retry." >&2
    exit 1
fi

echo "Installed iMCP for iOS."
if [[ -n "$expiration" ]]; then
    echo "Its profile expires on $expiration; rerun this script before then."
fi
echo "Next: in iMCP on your Mac, open Settings > iPhone & iPad and click Pair iPhone or iPad,"
echo "then open iMCP on the device and scan the code."
