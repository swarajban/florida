#!/bin/sh
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:?Missing Xcode Cloud checkout path}/apple"
if ! command -v xcodegen >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
fi
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-8G7N7547R6}" xcodegen generate --spec project.yml

for file in project.pbxproj xcshareddata/xcschemes/Florida-iOS.xcscheme xcshareddata/xcschemes/Florida-macOS.xcscheme; do
    if [ ! -s "Florida.xcodeproj/$file" ]; then
        echo "XcodeGen did not produce Florida.xcodeproj/$file" >&2
        exit 1
    fi
done

swiftpm=Florida.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$swiftpm"
cp Package.resolved "$swiftpm/Package.resolved"
