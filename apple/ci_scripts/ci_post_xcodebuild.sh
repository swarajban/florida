#!/bin/sh
set -eu

[ "${CI_XCODEBUILD_ACTION:-}" = test-without-building ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:?Missing xcodebuild exit code}" = 0 ] || exit 0
bundle="${CI_RESULT_BUNDLE_PATH:?Missing test result bundle path}"
[ -d "$bundle" ] || { echo "Test result bundle does not exist: $bundle" >&2; exit 1; }

python3 - "$bundle" <<'PY'
import json
import subprocess
import sys

try:
    # The structured subcommand on Xcode 26/27 does not take the legacy object API's flag.
    raw = subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", sys.argv[1]]
    )
    pending = json.loads(raw)["testNodes"]
    if not isinstance(pending, list):
        raise ValueError("testNodes is not a list")
    passed = 0
    while pending:
        node = pending.pop()
        pending.extend(node.get("children", []))
        if node["nodeType"] != "Test Case":
            continue
        result = node["result"]
        if result == "Passed":
            passed += 1
        elif result not in ("Skipped", "Disabled", "Not Run"):
            sys.exit(f"Test did not pass: {node['nodeIdentifier']} ({result})")
except (AttributeError, KeyError, OSError, TypeError, ValueError, subprocess.CalledProcessError) as error:
    sys.exit(f"Could not verify test results: {error}")

if not passed:
    sys.exit("No tests executed successfully")
print(f"Verified {passed} passing test cases and no failures")
PY
