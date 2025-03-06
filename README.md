<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/hero-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/hero-light.svg">
  <img alt="iMCP">
</picture>

iMCP is a macOS app for connecting your digital life with AI.
It works with [Claude Desktop][claude-app], [Cursor][cursor-app], 
and a growing list of clients that support the 
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
      <img src="Assets/messages.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Messages</strong></td>
    <td>Access message history with specific participants within customizable date ranges.</td>
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
      <img src="Assets/weather.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Weather</strong></td>
    <td>Access current weather conditions including temperature, wind speed, and weather conditions for any location.</td>
  </tr>
</table>

> [!TIP]
> Have a suggestion for a new capability? 
> Reach out to us at <imcp@loopwork.com>

## Getting Started

### Download and open the app

First, [download the iMCP app](https://github.com/loopwork-ai/iMCP/releases/latest) 
(requires macOS 15 or later).

<img align="right" width="344" src="/Assets/imcp-screenshot-first-launch.png" alt="Screenshot of iMCP on first launch" />

When you open the app,
you'll see a 
<img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
icon in your menu bar.

Clicking on this icon reveals the iMCP menu, 
which displays all available services. 
Initially, all services will appear in gray, 
indicating they're inactive.

The blue toggle switch at the top indicates that the MCP server is running 
and ready to connect with MCP-compatible clients.

<br clear="all">

<img align="right" width="372" src="/Assets/imcp-screenshot-grant-permission.png" alt="Screenshot of macOS permission dialog" />

> [!IMPORTANT]
> iMCP _does not_ collect or store any of your data 
> but MCP clients like Claude Desktop _do_ send 
> your data off device as part of tool calls. 

### Activate services

To activate a service, click on its icon. 
The system will prompt you with a permission dialog.
For example, when activating Calendar access, you'll see a dialog asking `"iMCP" Would Like Full Access to Your Calendar`.
Click <kbd>Allow Full Access</kbd> to continue.

<br clear="all">

<img align="right" width="344" src="/Assets/imcp-screenshot-all-services-active.png" alt="Screenshot of iMCP with all services enabled" />

Once activated,
each service icons goes from gray to their distinctive colors — 
red for Calendar, green for Messages, blue for Location, and so on.

Repeat this process for all of the capabilities you'd like to enable.
These permissions follow Apple's standard security model, 
giving you complete control over what information iMCP can access.

<!-- <br clear="all"> -->

<!-- <img align="right" width="344" src="/Assets/imcp-screenshot-configure-claude-desktop.png" /> -->

<br clear="all">

### Connect to Claude Desktop

If you don't have Claude Desktop installed, [you can download it here.](https://claude.ai/download)

Before you can enable MCP servers in Claude Desktop, you'll need to enable Developer Mode under `Settings...`.

To connect iMCP to Claude Desktop,
click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" /> > "Configure Claude Desktop" in the iMCP menu.

You'll be prompted to open the Claude Desktop configuration file
(`~/Library/Application Support/Claude/claude_desktop_config.json`).

This will add or update the MCP server configuration to use the
`imcp-server` executable bundled in the application. 
Other MCP server configurations in the file will be preserved.

### Open Claude Desktop

Open the Claude Desktop app.
You'll be prompted to approve the connection.

> [!NOTE]  
> In the case of Claude Desktop specifically, 
> you may see this dialog twice;
> click approve both times.

<br clear="all">

<!-- <p align="center">
  <img width="372" src="/Assets/imcp-screenshot-approve-connection.png" />
</p> -->

After approving the connection, 
you should now see 🔨12 in the bottom right corner of your chat box. 
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

### Connect to Cursor

Navigate to Cursor's Settings... > Cursor Settings > MCP  and click  <kbd>+ Add New MCP Server</kbd>

You can name the server "iMCP" and leave it as type "Command". To get the Command, click on the iMCP menu icon (<img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />) > "Copy server command to clipboard" and then paste the command from your clipboard into the "Command" field. It will look something like:

> /private/var/folders/...A BUNCH OF UNIQUE STUFF... /MacOS/imcp-server


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

This project is licensed under the Apache License, Version 2.0.

## Legal

This project is not affiliated with, endorsed, or sponsored by Apple Inc.

[claude-app]: https://claude.ai/download
[cursor-app]: https://www.cursor.com
[mcp]: https://modelcontextprotocol.io/introduction