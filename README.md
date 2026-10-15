<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/hero-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/hero-light.svg">
  <img src="Assets/hero-light.svg" alt="iMCP">
</picture>

iMCP is a macOS app for connecting your digital life with AI.
It works with [ChatGPT Desktop][chatgpt-app],
[Claude Desktop][claude-app],
local models served by [llama.cpp][llama-cpp],
and a [growing list of clients][mcp-clients] that support the
[Model Context Protocol (MCP)][mcp].

## Capabilities

<table>
  <tr>
    <th>
      <img src="Assets/calendar.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Calendar</strong></td>
    <td>View and manage calendar events, including creating new events with customizable settings like recurrence, alarms, and availability status.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/contacts.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Contacts</strong></td>
    <td>Access contact information about yourself and search your contacts by name, phone number, or email address.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/location.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Location</strong></td>
    <td>Access current location data and convert between addresses and geographic coordinates.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/maps.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Maps</strong></td>
    <td>Provides location services including place search, directions, points of interest lookup, travel time estimation, and static map image generation.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/messages.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Messages</strong></td>
    <td>Access message history with specific participants within customizable date ranges.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/phone.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Phone</strong></td>
    <td>View call history synced from your iPhone, filter calls by participant, date, or call type, and start calls with system confirmation.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/reminders.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Reminders</strong></td>
    <td>View and create reminders with customizable due dates, priorities, and alerts across different reminder lists.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/shortcuts.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Shortcuts</strong></td>
    <td>List and run shortcuts on your Mac, with optional text input.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/weather.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Weather</strong></td>
    <td>Access current weather conditions including temperature, wind speed, and weather conditions for any location.</td>
  </tr>
</table>

## Getting Started

To use iMCP, you need two apps:
iMCP, which gives access to the services you turn on,
and an AI app that can connect to MCP servers.
Install iMCP and turn on services first.
Then follow the instructions for your AI app:

- [ChatGPT Desktop](#connect-to-chatgpt-desktop)
- [Claude Desktop](#connect-to-claude-desktop)
- [Claude Code, Cursor, and other clients](#connect-to-other-clients)

### Download and open the app

First, [download the iMCP app](https://iMCP.app/download)
(requires macOS 15.3 or later).

Or, if you have [Homebrew](https://brew.sh) installed,
you can run the following command:

```console
brew install --cask mattt/tap/iMCP
```

<img align="right" width="344" src="/Assets/imcp-screenshot-first-launch.png" alt="Screenshot of the iMCP menu, with the Enable MCP Server switch at the top and a list of services below it" />

When you open the app,
you'll see a
<img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
icon in your menu bar.

Clicking on this icon reveals the iMCP menu.
The blue "Enable MCP Server" switch at the top indicates that
the MCP server is running and ready to connect with AI apps.
iMCP must be open for AI apps to use it.

Below the switch, the menu lists the available services.
Maps is on when you first open iMCP;
the other services are off and appear in gray.
iMCP also includes a tool that plays a system sound.
That tool is always available, even with every service off,
so you can test a connection without granting any permissions.

<br clear="all">

<img align="right" width="372" src="/Assets/imcp-screenshot-grant-permission.png" alt="Screenshot of macOS permission dialog" />

### Activate services

To activate a service, click on its icon.
The system will prompt you with a permission dialog.
For example, when activating Calendar access, you'll see a dialog asking `"iMCP" Would Like Full Access to Your Calendar`.
Click <kbd>Allow Full Access</kbd> to continue.

> [!IMPORTANT]
> iMCP **does not** collect or store any of your data.
> AI apps like ChatGPT and Claude _do_ send
> your data off device as part of tool calls.
> To keep your data on your Mac,
> [use a local model with llama.cpp](#llamacpp).
> Turn on only the services you want your AI app to use.

<br clear="all">

<img align="right" width="344" src="/Assets/imcp-screenshot-all-services-active.png" alt="Screenshot of iMCP with all services enabled" />

Once activated,
each service icon changes from gray to its own color:
red for Calendar, green for Messages, blue for Location, and so on.

Repeat this process for all of the capabilities you'd like to enable.
These permissions follow Apple's standard security model,
giving you complete control over what information iMCP can access.
To turn off a service, click its icon again.
To turn off individual tools within a service,
click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
\> "Settings..." and choose "Services".

<br clear="all">

### Approve connections

<img align="right" width="372" src="/Assets/imcp-screenshot-approve-connection.png" alt="Screenshot of the iMCP Connection Request dialog with Deny and Allow buttons" />

The first time an AI app connects,
iMCP shows a "Client Connection Request" dialog
with the name the app reports
and the services that the app can use.
Click "Allow" to connect.
Check "Always trust this client" to skip this dialog next time;
iMCP then shows a notification each time the app connects.
You can remove trusted clients in
<img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
\> "Settings..." > "General".

<br clear="all">

### Connect to ChatGPT Desktop

If you don't have ChatGPT Desktop installed,
you can [download it here][chatgpt-app].

> [!NOTE]
> These steps use the labels in ChatGPT 26.930 for macOS
> and haven't been tested end to end yet.
> OpenAI documents MCP servers for
> [Codex mode](https://learn.chatgpt.com/docs/extend/mcp),
> so use iMCP in a Codex conversation.

1. Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
   \> "Copy server command to clipboard".
2. In ChatGPT, open Settings (<kbd>⌘</kbd><kbd>,</kbd>)
   and choose "MCP servers" in the sidebar.
3. Choose "Add server".
   Enter `iMCP` for "Name", choose "STDIO" for "Type",
   and paste the copied command into "Command to launch".
   Leave the other fields empty.
4. Choose "Save", and then choose "Restart".
5. [Approve the connection](#approve-connections) in iMCP.
   ChatGPT might identify itself as `codex-mcp-client`.

To test the connection,
start a new Codex conversation and send this message:

> "Use iMCP to play a system sound."

Your Mac plays a short sound.
If your Mac is muted, open the tool call in the conversation;
a result of `true` means that iMCP received the request.

<details>
<summary>Troubleshooting ChatGPT Desktop</summary>

- **Settings doesn't show "MCP servers".**
  Update ChatGPT and switch to Codex mode.
  If ChatGPT shows "MCP server settings are unavailable"
  and an organization manages your account,
  ask your administrator whether you can add MCP servers.
- **iMCP doesn't show an approval dialog.**
  ChatGPT can't open iMCP for you.
  Make sure that iMCP is open and "Enable MCP Server" is on,
  and then choose "Restart" in ChatGPT's "MCP servers" settings.
  The dialog can also open behind other windows.
  If you trusted ChatGPT before,
  iMCP shows a notification instead of a dialog.
- **ChatGPT can't use iMCP tools.**
  Make sure that you're in a Codex conversation
  and that iMCP is turned on in ChatGPT's "MCP servers" settings.
  If you clicked "Deny", choose "Restart" to see the dialog again.
  If you turned on a service after connecting, choose "Restart"
  so that ChatGPT loads its tools.
- **A service doesn't turn on in iMCP.**
  If you denied permission when macOS asked,
  open System Settings > "Privacy & Security",
  choose the category for the service, such as "Calendars",
  and turn on iMCP.
  Then click the service icon in the iMCP menu again.
- **ChatGPT shows an error for the iMCP server.**
  The command might point to the wrong place,
  for example, if you moved iMCP after setting it up.
  Copy the server command again,
  open the iMCP server's settings in ChatGPT,
  and replace "Command to launch" with the copied command.
  Make sure that "Arguments" is empty,
  and then choose "Save" and "Restart".

</details>

### Connect to Claude Desktop

If you don't have Claude Desktop installed,
you can [download it here](https://claude.ai/download).

Open Claude Desktop and go to "Settings... (<kbd>⌘</kbd><kbd>,</kbd>)".
Click on "Developer" in the sidebar of the Settings pane,
and then click on "Edit Config".
This will create a configuration file at
`~/Library/Application Support/Claude/claude_desktop_config.json`.

<br/>

To connect iMCP to Claude Desktop,
click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
\> "Configure Claude Desktop",
and then click "Set Up".

This will add or update the MCP server configuration to use the
`imcp-server` executable bundled in the application.
Other MCP server configurations in the file will be preserved.

<details>
<summary>You can also configure Claude Desktop manually</summary>

Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
\> "Copy server command to clipboard".
Then open `claude_desktop_config.json` in your editor
and enter the following:

```json
{
  "mcpServers": {
    "iMCP": {
      "command": "{paste iMCP server command}"
    }
  }
}
```

</details>

### Call iMCP tools from Claude Desktop

Quit and reopen the Claude Desktop app.
iMCP will ask you to [approve the connection](#approve-connections).

After approving the connection,
you should now see a 🔨 icon with the number of available tools
in the bottom right corner of your chat box.
Click on that to see a list of all the tools made available to Claude
by iMCP.

<p align="center">
  <img width="694" src="/Assets/claude-desktop-screenshot-tools-enabled.png" alt="Screenshot of Claude Desktop with tools enabled" />
</p>

Now you can ask Claude questions that require access to your personal data,
such as:

> "How's the weather where I am?"

Claude will use the appropriate tools to retrieve this information,
providing you with accurate, personalized responses
without requiring you to manually share this data during your conversation.

<p align="center">
  <img width="738" src="/Assets/claude-desktop-screenshot-message.png" alt="Screenshot of Claude response to user message 'How's the weather where I am?'" />
</p>

### Connect to other clients

Most MCP clients can start iMCP as a local server
that uses the STDIO transport.
Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
\> "Copy server command to clipboard",
and then enter the copied command
as the command for a new STDIO server in your client.
The copied command is the full path to the `imcp-server` executable
in your copy of iMCP.

The commands below assume that iMCP is in your Applications folder.
If you installed iMCP somewhere else,
replace `/Applications/iMCP.app/Contents/MacOS/imcp-server`
with the copied command.

#### [Claude Code][claude-code]

To add iMCP globally after installing the app:

```console
claude mcp add --scope user iMCP -- /Applications/iMCP.app/Contents/MacOS/imcp-server
```

<details>
<summary>Or import from Claude Desktop</summary>

If you've already configured Claude Desktop, you can import its MCP servers:

```console
claude mcp add-from-claude-desktop
```

</details>

#### [Cursor][cursor]

Open this deep link to automatically install the iMCP server:

<a href="https://cursor.com/en-US/install-mcp?name=iMCP&config=eyJjb21tYW5kIjoiL0FwcGxpY2F0aW9ucy9pTUNQLmFwcC9Db250ZW50cy9NYWNPUy9pbWNwLXNlcnZlciAifQ%3D%3D">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://cursor.com/deeplink/mcp-install-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://cursor.com/deeplink/mcp-install-light.svg">
    <img alt="Install MCP Server" src="https://cursor.com/deeplink/mcp-install-light.svg">
  </picture>
</a>

#### [llama.cpp][llama-cpp]

You can use iMCP with an open model that runs on your Mac
through [llama.cpp][llama-cpp],
so your conversations and tool results stay on your Mac.
`llama-server` (or `llama serve`) starts the MCP servers
listed in a configuration file
and gives their tools to models in its web UI.
This requires llama.cpp 0.1.0 or later.

Create a file at `~/.config/llama/mcp.json` with the following contents:

```json
{
  "mcpServers": {
    "imcp": {
      "command": "/Applications/iMCP.app/Contents/MacOS/imcp-server"
    }
  }
}
```

Then start the server with the `--mcp-servers-config` option
and a model that supports tool calling:

```console
llama serve --mcp-servers-config ~/.config/llama/mcp.json \
            -hf ggml-org/Qwen3-4B-GGUF
```

Open the web UI at <http://localhost:8080>.
iMCP tools show up with an `imcp_` prefix,
such as `imcp_weather_current`.
The web UI asks you before it runs each tool call,
unless you choose to always allow that tool.

<details>
<summary>Use the Llama app</summary>

[Llama][llama-app] is a menu bar app that runs `llama serve` for you.
It doesn't have a setting for MCP servers,
so add the `--mcp-servers-config` option to its custom server arguments:

```console
defaults write app.llama.Llama extraServerArgs -string "--mcp-servers-config $HOME/.config/llama/mcp.json"
```

Llama splits this value at each space and doesn't expand `~`,
so use the full path to the file, without spaces.
If you already set custom server arguments,
add the option to your existing value.
Quit and reopen Llama,
then open the web UI at <http://localhost:9931>.

</details>

> [!TIP]
> When the server starts,
> it waits 10 seconds for iMCP to list its tools.
> If you don't [approve the connection](#approve-connections)
> from "llama.cpp" in that time,
> no iMCP tools show up until you restart the server.

## Technical Details

### App & CLI

iMCP is a macOS app that bundles a command-line executable, `imcp-server`.

- [`iMCP.app`](/App/) provides UI for configuring services and — most importantly —
  a means of interacting with macOS system permissions,
  so that it can access Contacts, Calendar, and other information.
- [`imcp-server`](/CLI/) provides an MCP server that
  uses standard input/output for communication
  ([stdio transport][mcp-transports]).

The app and CLI communicate with each other on the local network
using [Bonjour][bonjour] for automatic discovery.
Both advertise a service with type "\_mcp.\_tcp" and domain "local".
Requests from MCP clients are read by the CLI from `stdin`
and relayed to the app;
responses from the app are received by the CLI and written to `stdout`.
See [`StdioProxy`](https://github.com/mattt/iMCP/blob/8cf9d250286288b06bf5d3dda78f5905ad0d7729/CLI/main.swift#L47)
for implementation details.

For this project, we created what became
[the official Swift SDK][swift-sdk]
for Model Context Protocol servers and clients.
The app uses this package to handle proxied requests from MCP clients.

### iMessage Database Access

Apple doesn't provide public APIs for accessing your messages.
However, the Messages app on macOS stores data in a SQLite database located at
`~/Library/Messages/chat.db`.

iMCP runs in [App Sandbox][app-sandbox],
which limits its access to user data and system resources.
When you go to enable the Messages service,
you'll be prompted to select your `~/Library/Messages` folder through the standard file picker.
When you do, macOS adds that folder to the app's sandbox.
[`NSOpenPanel`][nsopenpanel] is magic like that.
The folder matters: `chat.db` is a WAL-mode database,
and Messages writes every new message to `chat.db-wal` next to it first,
only folding the log into `chat.db` at a checkpoint every few MB —
often hours later.
A grant on `chat.db` alone (what earlier versions asked for)
leaves that log unreadable, so the newest messages were missing until then.
If you granted `chat.db` with an earlier version, Messages keeps working from the last checkpoint;
switch Messages off and on in the iMCP menu to grant the folder instead.

But opening the iMessage database is just half the battle.
Over the past few years,
Apple has moved away from storing messages in plain text
and instead toward a proprietary `typedstream` format.

For this project, we created [Madrid][madrid]:
a Swift package for reading your iMessage database.
It includes a Swift implementation for decoding Apple's `typedstream` format,
adapted from Christopher Sardegna's [imessage-exporter] project
and [blog post about reverse-engineering `typedstream`][typedstream-blog-post].

### Call History Database Access

Call history synced from your iPhone lives in a SQLite database at
`~/Library/Application Support/CallHistoryDB/CallHistory.storedata`.
Recent calls sit in its write-ahead log next to the store file,
so the Phone service asks you to open the `CallHistoryDB` folder
rather than the file alone.

### JSON-LD for Tool Results

The tools provided by iMCP return results as
[JSON-LD][json-ld] documents.
For example,
the `fetchContacts` tool uses the [Contacts framework][contacts-framework],
which represents people and organizations with the [`CNContact`][cncontact] type.
Here's how an object of that type is encoded as JSON-LD:

```json
{
  "@context": "https://schema.org",
  "@type": "Person",
  "name": "Mattt",
  "url": "https://mat.tt"
}
```

[Schema.org][schema.org] provides standard vocabularies for
people, postal addresses, events, and many other objects we want to represent.
And JSON-LD is a convenient encoding format for
humans, AI, and conventional software alike.

For this project, we created [Ontology][ontology]:
a Swift package for working with structured data.
It includes convenience initializers for types from Apple frameworks,
such as those returned by iMCP tools.

## Debugging

### Using the MCP Inspector

To debug interactions between iMCP and clients,
you can use the [inspector tool](https://github.com/modelcontextprotocol/inspector)
(requires Node.js):

1. Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" /> > "Copy server command to clipboard"
2. Open a terminal and run the following commands:

   ```console
   # Download and run inspector package on imcp-server
   npx @modelcontextprotocol/inspector [paste-copied-command]

   # Open inspector web app running locally
   open http://127.0.0.1:6274
   ```

Inspector lets you see all requests and responses between the client and the iMCP server,
which is helpful for understanding how the protocol works.

### Using Companion

<img align="right" width="284" src="/Assets/companion-screenshot-add-server.png" />

[Companion][companion] is a utility for testing and debugging your MCP servers
(requires macOS 15 or later).
It gives you an easy way to browse and interact with
a server's prompts, resources, and tools.
Here's how to connect it to iMCP:

1. Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" /> > "Copy server command to clipboard"
2. [Download][companion-download] and open the Companion app
3. Click the <kbd>+</kbd> button in the toolbar to add an MCP server
4. Fill out the form:
   - Enter "iMCP" as the name
   - Select "STDIO" as the transport
   - Paste the copied iMCP server command
   - Click "Add Server"

<br clear="all">

## Acknowledgments

- [Justin Spahr-Summers](https://jspahrsummers.com/)
  ([@jspahrsummers](https://github.com/jspahrsummers)),
  David Soria Parra
  ([@dsp-ant](https://github.com/dsp-ant)), and
  Ashwin Bhat
  ([@ashwin-ant](https://github.com/ashwin-ant))
  for their work on MCP.
- [Christopher Sardegna](https://chrissardegna.com)
  ([@ReagentX](https://github.com/ReagentX))
  for reverse-engineering the `typedstream` format
  used by the Messages app.

## License

This project is available under the MIT license.
See the LICENSE file for more info.

## Legal

iMessage® is a registered trademark of Apple Inc.
This project is not affiliated with, endorsed, or sponsored by Apple Inc.

[app-sandbox]: https://developer.apple.com/documentation/security/app-sandbox
[bonjour]: https://developer.apple.com/bonjour/
[chatgpt-app]: https://chatgpt.com/download
[claude-app]: https://claude.ai/download
[claude-code]: https://claude.com/product/claude-code
[companion]: https://github.com/mattt/Companion
[companion-download]: https://github.com/mattt/Companion/releases/latest/download/Companion.zip
[contacts-framework]: https://developer.apple.com/documentation/contacts
[cncontact]: https://developer.apple.com/documentation/contacts/cncontact
[cursor]: https://cursor.com
[imessage-exporter]: https://github.com/ReagentX/imessage-exporter
[json-ld]: https://json-ld.org
[llama-app]: https://llama.app
[llama-cpp]: https://github.com/ggml-org/llama.cpp
[madrid]: https://github.com/mattt/Madrid
[mcp]: https://modelcontextprotocol.io/introduction
[mcp-clients]: https://modelcontextprotocol.io/clients
[mcp-transports]: https://modelcontextprotocol.io/docs/concepts/architecture#transport-layer
[nsopenpanel]: https://developer.apple.com/documentation/appkit/nsopenpanel
[ontology]: https://github.com/mattt/Ontology
[schema.org]: https://schema.org
[swift-sdk]: https://github.com/modelcontextprotocol/swift-sdk
[typedstream-blog-post]: https://chrissardegna.com/blog/reverse-engineering-apples-typedstream-format/
