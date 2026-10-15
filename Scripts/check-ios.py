# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check the iPhone and iPad tools through imcp-server without changing anything.

Turn on Health, Finance, or Alarms in iMCP first.
The checks pass whether or not an iPhone or iPad is connected:
reads then come from the Mac's cache and must say so.
"""

import argparse
import json
import os
import select
import subprocess
import time
from pathlib import Path

TOOLS = {
    "health_fetch",
    "health_statistics",
    "workouts_fetch",
    "clinical_records_fetch",
    "finance_accounts_list",
    "finance_balances_fetch",
    "finance_transactions_fetch",
    "alarms_list",
    "alarms_create",
    "timers_create",
    "alarms_cancel",
    "mobile_status",
}
WRITES = {"alarms_create", "timers_create", "alarms_cancel"}
READ_ARGUMENTS = {
    "health_statistics": {"type": "stepCount", "interval": "day"},
    "health_fetch": {"type": "sleepAnalysis", "limit": 5},
    "workouts_fetch": {"limit": 5},
    "clinical_records_fetch": {"limit": 5},
    "finance_accounts_list": {},
    "finance_balances_fetch": {"limit": 5},
    "finance_transactions_fetch": {"limit": 5},
    "alarms_list": {},
}


class Client:
    def __init__(self, server: Path, service_type: str):
        self.process = subprocess.Popen(
            [str(server.resolve())],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={**os.environ, "IMCP_SERVICE_TYPE": service_type},
        )
        self.sequence = 0
        self.buffer = b""
        try:
            self.request(
                "initialize",
                {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "iMCP iOS checks", "version": "1.0"},
                },
            )
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except BaseException:
            self.close()
            raise

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        self.send(
            {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        )
        # Allow time to approve the connection in iMCP.
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                ready, _, _ = select.select(
                    [self.process.stdout], [], [], max(0, deadline - time.monotonic())
                )
                if not ready:
                    raise TimeoutError(f"Timed out waiting for {method}")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("imcp-server closed its output")
                self.buffer += chunk
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") != self.sequence:
                continue
            if "error" in response:
                raise RuntimeError(response["error"])
            return response["result"]
        raise TimeoutError(f"Timed out waiting for {method}")

    def call(self, name, arguments=None):
        """Return (ok, value): parsed JSON on success, or the error text."""
        result = self.request(
            "tools/call", {"name": name, "arguments": arguments or {}}
        )
        text = result["content"][0]["text"]
        if result.get("isError"):
            return False, text
        return True, json.loads(text)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def check_envelope(name, value):
    assert value["source"] in ("live", "cache"), (name, value)
    assert isinstance(value["stale"], bool), (name, value)
    assert "synced_at" in value, (name, value)
    assert isinstance(value["results"], list), (name, value)
    if value["source"] == "live":
        assert value["stale"] is False, (name, value)
    if value["synced_at"] is None:
        assert value["stale"] is True, (name, value)


def check(client):
    tools = {tool["name"]: tool for tool in client.request("tools/list", {})["tools"]}
    present = TOOLS & tools.keys()
    assert "mobile_status" in present, (
        "No mobile tools are listed. Turn on Health, Finance, or Alarms in iMCP."
    )
    for name in present:
        annotations = tools[name]["annotations"]
        assert annotations["openWorldHint"] is False, name
        assert annotations["readOnlyHint"] == (name not in WRITES), name
        assert annotations["destructiveHint"] == (name == "alarms_cancel"), name
        schema = tools[name]["inputSchema"]
        if "anyOf" not in schema:
            assert schema["additionalProperties"] is False, name

    ok, status = client.call("mobile_status")
    assert ok, status
    print(
        f"Paired devices: {', '.join(status['paired_devices']) or 'none'}; "
        f"connected: {status['connected']}."
    )
    for domain, service in status["services"].items():
        print(
            f"  {domain}: synced {service['synced_at'] or 'never'}, stale {service['stale']}"
        )

    for name, arguments in READ_ARGUMENTS.items():
        if name not in present:
            continue
        ok, value = client.call(name, arguments)
        if not ok:
            # Finance reports why it's unavailable, such as a missing entitlement.
            assert name.startswith("finance_") or "locked" in value, (name, value)
            print(f"  {name}: {value}")
            continue
        check_envelope(name, value)
        print(
            f"  {name}: {len(value['results'])} results from {value['source']}, "
            f"stale {value['stale']}"
        )

    invalid = [
        ("health_fetch", {}),
        ("workouts_fetch", {"limit": "5"}),
        ("health_statistics", {"type": "stepCount", "interval": "fortnight"}),
        ("finance_transactions_fetch", {"status": "lost"}),
        ("alarms_cancel", {}),
        ("timers_create", {"title": "Do not create", "duration_seconds": 0}),
        (
            "alarms_create",
            {
                "title": "Do not create",
                "fire_at": "2030-01-01T06:00:00Z",
                "hour": 6,
                "minute": 0,
            },
        ),
    ]
    for name, arguments in invalid:
        if name not in present:
            continue
        ok, value = client.call(name, arguments)
        assert not ok, (name, arguments, value)
    print("Tool schemas, annotations, sync status, and invalid-input checks passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "server", type=Path, help="Path to the built imcp-server executable"
    )
    parser.add_argument("--service-type", default="_mcp._tcp")
    args = parser.parse_args()
    client = None
    try:
        client = Client(args.server, args.service_type)
        check(client)
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    main()
