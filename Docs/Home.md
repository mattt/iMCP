# HomeKit tools

The Home service uses a signed Mac Catalyst helper inside
`iMCP.app/Contents/Helpers/iMCP Home.app`.
The native app starts the helper when you enable Home.
The helper requests HomeKit access and exits when its parent app exits.
Its status window reports startup and permission errors.

## Build

Build the `iMCP` scheme for macOS.
The build phase runs the `iMCP Home` scheme for Mac Catalyst in a separate
build directory, then copies the helper into the app.
A direct target dependency selects the iOS variant under Xcode 27,
so the separate build is required.
The nested build uses a clean environment to avoid inheriting native app
product names and SDK settings.

The helper uses automatic development signing with team `TTY35UM57S`
in both configurations.
The native Debug app can remain unsigned while its helper is signed.
The helper requires a development certificate and a HomeKit provisioning profile.
On another developer account, change the helper's team in Xcode.
If automatic provisioning initially cannot include HomeKit,
enable HomeKit in Signing & Capabilities for the iOS destination first.
An iOS build with `-allowProvisioningUpdates` also registered the capability
for this project's bundle ID during local setup.

```sh
xcodebuild -scheme "iMCP Home" -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -allowProvisioningUpdates build
```

CI builds both apps without signing:

```sh
xcodebuild -quiet -scheme iMCP -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  HOME_HELPER_CODE_SIGNING_ALLOWED=NO build
```

Unsigned builds check compilation and packaging.
They cannot test HomeKit access.
Release distribution and notarization of the nested app remain separate work.
The release script has not changed.

## Access and discovery

Enable Home in iMCP, then allow HomeKit access when macOS asks.
The Mac's iCloud account must have access to the home.
Writes can require the home owner or administrator role.
If access is denied, check System Settings → Privacy & Security → HomeKit.
Bonjour can also require local network permission.

The helper binds its TCP listener to `127.0.0.1`.
For automatic launch, the native app selects an ephemeral loopback port
and passes it to the helper with `--port`.
This connection does not depend on Bonjour.
A manually started helper publishes `_imcp-home._tcp` through the DNS-SD
local-only interface, with `localhost` as its host.
That service is visible only on this Mac.
`acceptLocalOnly` alone restricts connections to the local network link;
it does not restrict them to the host.
The explicit loopback binding provides that restriction.
See [Apple's acceptLocalOnly documentation](https://developer.apple.com/documentation/network/nwparameters/acceptlocalonly).

The native service retries connections while the launched helper starts.
For a manually started helper, it uses Bonjour with a 15-second timeout.
Bonjour registration stalled during local testing on macOS 27.
If manual discovery fails, quit the helper and let iMCP launch it.
It checks `homes_list` before activation succeeds.
Settings can list all 28 tools while the helper is stopped because both targets
use the same definitions in `Shared/Home/HomeTools.swift`.
The normal service and per-tool switches apply to calls through iMCP.
Other local processes can connect directly to the helper while it is running.

## Behavior

Home IDs and object IDs are HomeKit UUID strings.
Omitting `home` selects the home only when exactly one home is available.
Batch reads and room assignment return a result for each requested ID.
An unknown ID does not abort other items in the batch.

Inventory calls omit live values unless `include_values` is true.
Reads have a five-second timeout, with no more than four outstanding HomeKit
read operations across requests.
A timed-out HomeKit operation still holds its slot until its callback arrives,
so unreachable devices cannot cause an unlimited number of pending reads.
Non-finite metadata values are represented as JSON `null`.

Write values are checked against the characteristic format, range,
step, and permitted values where available.
Unsigned 64-bit values are limited to the exact integer range of JSON numbers
used by this implementation, from 0 through 9007199254740991.
Data and TLV8 values use base64 strings.
All objects in a room, zone, scene, or automation operation must belong
to the same home.

Failed scene, zone, and automation creation attempts remove the partially
created object where possible.
If cleanup fails, the error includes its ID.
Multi-step updates can make partial changes before HomeKit reports an error.
Inspect the object before retrying a failed update.

After a connection failure, the proxy reconnects once.
Read-only calls retry once.
Writes are not repeated automatically because HomeKit may have applied a write
before the connection failed.
The error instructs the caller to inspect the home before retrying.

HomeKit exposes only part of some Home app automations and Shortcuts actions.
Exports include trigger-owned action sets as well as ordinary scenes.
Unknown event and action types are marked unsupported.
Apple deprecated `lastFireDate` in Mac Catalyst 17 without a replacement;
the field is always `null`.

Timer fire dates must fall on a whole-minute boundary.
Pairing accessories and renaming homes are outside this tool set.

## Checks

With a manually started signed helper and working Bonjour discovery,
run the read-only integration check:

```sh
uv run Scripts/check-home.py /path/to/imcp-server
```

The check uses `IMCP_SERVICE_TYPE=_imcp-home._tcp` to connect directly to the helper.
It checks the tool count, annotations, inventory, Default Room filter,
and error handling without changing HomeKit data.
The same environment variable lets MCP Inspector use the helper directly.
The default CLI service type remains `_mcp._tcp`.

The feasibility mode is available with the `--spike` launch argument.
It exports `homekit-spike.json` to the helper's Application Support directory
and writes JSON to standard output.
Adding `--rename-accessory <UUID>` performs a rename-and-restore check.
It saves the original name in `rename-recovery.json` before the first write,
and removes the recovery file after restoration succeeds.
An existing recovery file prevents another rename test.
Review that file and restore the original name before removing it.

The initial local feasibility check loaded one home with 112 accessories,
including 95 bridged accessories, in about 0.08 seconds.
Both timer and event triggers appeared in the export.
A reachable sconce completed the rename-and-restore check.
These observations confirm API access on the development Mac;
they do not establish support for every accessory or Home app automation.

The optional proxy integration test starts a signed helper, reads the home,
checks remote errors, terminates the helper, and checks automatic recovery.
Set `TEST_RUNNER_IMCP_HOME_HELPER_PATH` to the signed helper app path when running
the `imcp-serverTests` scheme.
Quit any manually started helper before this test.
