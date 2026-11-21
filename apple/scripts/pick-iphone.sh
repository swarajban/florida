#!/usr/bin/env bash
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json, sys

phones = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS-" not in runtime:
        continue
    version = tuple(map(int, runtime.rsplit("iOS-", 1)[1].split("-")))
    for device in devices:
        name = device["name"]
        if not name.startswith("iPhone") or not device.get("isAvailable", True):
            continue
        priority = 4 if name == "iPhone 17 Pro Max" else 3 if name == "iPhone 17 Pro" else 2 if "Pro Max" in name else 1
        phones.append((priority, version, name, device["udid"]))

if not phones:
    sys.exit("No available iPhone simulators on this runner")
_, version, name, udid = max(phones)
runtime = ".".join(map(str, version))
print(f"Using {name} (iOS {runtime}, {udid})", file=sys.stderr)
print(udid)
'
