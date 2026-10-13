# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check the running iMCP Helper through imcp-server without changing the home."""

import argparse
import json
import os
import select
import subprocess
import time
from pathlib import Path


class HomeClient:
    def __init__(self, server: Path, service_type: str = "_imcp-helper._tcp"):
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
                    "clientInfo": {"name": "iMCP Helper checks", "version": "1.0"},
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
        deadline = time.monotonic() + 45
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

    def call(self, name, arguments=None, *, error=False):
        result = self.request(
            "tools/call", {"name": name, "arguments": arguments or {}}
        )
        assert bool(result.get("isError")) == error, result
        text = result["content"][0]["text"]
        return text if error else json.loads(text)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def check(client):
    tools = client.request("tools/list", {})["tools"]
    assert len(tools) == 28
    assert len({tool["name"] for tool in tools}) == 28
    destructive = {
        "accessories_remove",
        "rooms_remove",
        "zones_remove",
        "scenes_remove",
        "automations_remove",
    }
    for tool in tools:
        annotations = tool["annotations"]
        assert annotations["openWorldHint"] is False
        assert annotations["destructiveHint"] == (tool["name"] in destructive)
        assert tool["inputSchema"]["additionalProperties"] is False
    homes = client.call("homes_list")["homes"]
    assert homes, "The helper is authorized but no homes are available"
    for home in homes:
        args = {"home": home["id"]}
        rooms = client.call("rooms_list", args)
        assert sum(room["isDefaultRoom"] for room in rooms) == 1
        client.call("zones_list", args)
        accessories = client.call("accessories_list", args)
        assert len(accessories) == home["accessories"]
        default = next(room["id"] for room in rooms if room["isDefaultRoom"])
        unassigned = client.call("accessories_list", {**args, "in_default_room": True})
        assert all(accessory["room"] == default for accessory in unassigned)
        graph = client.call("home_export", args)
        assert len(graph["accessories"]) == len(accessories)
        client.call("scenes_list", args)
        client.call("automations_list", args)
        if accessories:
            detail = client.call("accessories_get", {"accessory": accessories[0]["id"]})
            assert detail["accessory"]["id"] == accessories[0]["id"]
            for service in detail["services"]:
                for characteristic in service["characteristics"]:
                    assert "value" not in characteristic
        print(
            f"Checked {len(rooms)} rooms, {len(accessories)} accessories, "
            f"and {len(unassigned)} accessories in the Default Room."
        )
    result = client.call("characteristics_read", {"characteristics": ["invalid-id"]})
    assert len(result) == 1 and result[0]["ok"] is False and result[0]["error"]
    client.call("accessories_get", {"accessory": "invalid-id"}, error=True)
    client.call("home_export", {"include_values": "yes"}, error=True)
    client.call(
        "rooms_create", {"name": "Do not create", "unexpected": True}, error=True
    )
    client.call("accessories_rename", {"accessory": "invalid-id"}, error=True)
    client.call(
        "automations_create",
        {"name": "Do not create", "scenes": [], "trigger": {"event": "noon"}},
        error=True,
    )
    print("Tool schemas, annotations, inventory, and invalid-input checks passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "server", type=Path, help="Path to the built imcp-server executable"
    )
    parser.add_argument("--service-type", default="_imcp-helper._tcp")
    args = parser.parse_args()
    client = None
    try:
        client = HomeClient(args.server, args.service_type)
        check(client)
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    main()
