# Security Policy

## Reporting a Vulnerability

Please don't report security vulnerabilities
in public issues, discussions, or pull requests.
Instead, report them privately through
[GitHub's reporting form](https://github.com/mattt/iMCP/security/advisories/new)
for this repository.

Please include:

- A description of the problem and its impact.
- Steps to reproduce it, or a proof of concept.
- The versions of iMCP and macOS that you tested,
  and the MCP client, if one is involved.

I'll acknowledge your report, keep you updated while I investigate,
and credit you in the advisory, unless you'd rather not be named.
Please test only with your own data and accounts,
and give me a chance to release a fix before you disclose the problem publicly.

## What Counts as a Vulnerability

iMCP is designed to give AI apps access to your personal data:
when you turn on a service and allow a client to connect,
that client can read and change what the service exposes.
That's intended behavior, not a vulnerability.

Please report problems that let something get around iMCP's controls, such as:

- Connecting to iMCP without your approval.
- Using a service that you turned off,
  or reading or changing data beyond what an enabled service exposes.
- Connecting to iMCP Helper without pairing with it.

## Supported Versions

Security fixes go into the latest release.
Please check that the problem still happens with
[the latest version](https://github.com/mattt/iMCP/releases/latest)
before you report it.

## Scope

This policy covers the code in this repository:
the iMCP app, the `imcp-server` command-line tool, and iMCP Helper.
Please report vulnerabilities in macOS, MCP clients, or other dependencies
to their maintainers.
