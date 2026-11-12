#!/usr/bin/env bash
set -euo pipefail

log=${1:?Usage: report-ui-failures.sh test.log}
[[ -f $log ]] || exit 0
failures=$(grep -E 'Test Case .* failed|Test case .* failed' "$log" || true)
[[ -n $failures ]] || exit 0
echo '::warning::UI failures were recorded; inspect first-attempt failures even if the retry passed.'
printf '### UI failures and retries\n\nAt most one retry per failed test. A passing retry is not a flake fix.\n\n~~~text\n%s\n~~~\n\nThe raw log and xcresult are uploaded as artifacts.\n' "$failures" >> "${GITHUB_STEP_SUMMARY:?}"
