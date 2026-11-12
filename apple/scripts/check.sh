#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
command=${1:-build}
shift "$(( $# > 0 ? 1 : 0 ))"
case "$command" in
  generate|build|ios|macos) ;;
  *) echo 'Usage: bash apple/scripts/check.sh {generate|build|ios|macos} [xcodebuild test options]' >&2; exit 2 ;;
esac
if [[ $(uname -s) != Darwin ]]; then
  echo 'App checks require a Mac with Xcode selected by xcode-select.' >&2
  exit 1
fi
mkdir -p build
if [[ ${TEST_WITHOUT_BUILDING:-0} != 1 ]]; then
  DEVELOPMENT_TEAM='' xcodegen generate
fi
[[ $command != generate ]] || exit 0

project=(-project Florida.xcodeproj -configuration Debug)
ios_signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
mac_signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
if [[ $command == build ]]; then
  xcodebuild build-for-testing "${project[@]}" -scheme Florida-iOS \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios \
    -clonedSourcePackagesDirPath build/SourcePackages "${ios_signing[@]}"
  xcodebuild build-for-testing "${project[@]}" -scheme Florida-macOS \
    -destination 'platform=macOS' -derivedDataPath build/macos \
    -clonedSourcePackagesDirPath build/SourcePackages "${mac_signing[@]}"
  exit 0
fi

action='test'
input=("${project[@]}" -scheme Florida-macOS -derivedDataPath build/macos -clonedSourcePackagesDirPath build/SourcePackages)
destination='platform=macOS'
signing=("${mac_signing[@]}")
if [[ $command == ios ]]; then
  input=("${project[@]}" -scheme Florida-iOS -derivedDataPath build/ios -clonedSourcePackagesDirPath build/SourcePackages)
  signing=("${ios_signing[@]}")
  UDID=${UDID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
ios = sorted((k for k in devices if "iOS-" in k), key=lambda k: [int(p) for p in k.split("iOS-")[-1].split("-")])
phones = [d for d in devices[ios[-1]] if d["name"].startswith("iPhone")]
pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]]
print((pro or phones)[0]["udid"])
')}
  destination="id=$UDID"
  if ! xcrun simctl list devices booted | grep -Fq "$UDID"; then
    xcrun simctl boot "$UDID"
  fi
  xcrun simctl bootstatus "$UDID" -b
  xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4
fi
if [[ ${TEST_WITHOUT_BUILDING:-0} == 1 ]]; then
  action=test-without-building
  runs=(build/"$command"/Build/Products/*.xctestrun)
  [[ ${#runs[@]} == 1 && -f ${runs[0]} ]] || { echo 'Expected one compiled xctestrun file; run build first.' >&2; exit 1; }
  input=(-xctestrun "${runs[0]}")
fi
mkdir -p build/results
result="build/results/$command-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
test_args=(-parallel-testing-enabled NO -resultBundlePath "$result")
if [[ ${RETRY_FAILED_TESTS:-0} == 1 ]]; then
  test_args+=(-retry-tests-on-failure -test-iterations 2)
fi
xcodebuild "$action" "${input[@]}" -destination "$destination" \
  "${test_args[@]}" "${signing[@]}" "$@"
