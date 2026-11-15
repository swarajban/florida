#!/usr/bin/env bash
set -euo pipefail

platform=${1:?Expected ios or macos}
case "$platform" in ios|macos) ;; *) exit 2 ;; esac
version=$(xcodebuild -version | shasum -a 256 | cut -d' ' -f1)
sha=$(git rev-parse HEAD)
name="apple-test-products-$sha-${RUNNER_ARCH:?}-$version"
directory=$(mktemp -d "$RUNNER_TEMP/test-products.XXXXXX")
trap 'rm -rf "$directory"' EXIT

restore() {
  local artifact
  artifact=$(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$name&per_page=100" \
    --jq '.artifacts | map(select(.expired == false)) | first | .id // empty') || return 1
  [[ -n $artifact ]] || return 1
  gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$artifact/zip" > "$directory/artifact.zip" || return 1
  unzip -q "$directory/artifact.zip" -d "$directory" || return 1
  tar -xzf "$directory/apple-tests.tgz" -C "$directory" \
    "$platform/Build/Products" xcode-version.txt source-sha.txt || return 1
  diff "$directory/xcode-version.txt" <(xcodebuild -version) || return 1
  [[ $(cat "$directory/source-sha.txt") == "$sha" ]] || return 1
  local runs=("$directory/$platform/Build/Products/"*.xctestrun)
  [[ ${#runs[@]} == 1 && -f ${runs[0]} ]] || return 1
  mkdir -p "apple/build/$platform/Build"
  rm -rf "apple/build/$platform/Build/Products"
  mv "$directory/$platform/Build/Products" "apple/build/$platform/Build/Products" || return 1
}

if restore; then
  echo 'TEST_WITHOUT_BUILDING=1' >> "$GITHUB_ENV"
  echo "Using exact-SHA $platform test products ($sha, Xcode $version)."
else
  echo 'TEST_WITHOUT_BUILDING=0' >> "$GITHUB_ENV"
  echo "No compatible test products available; building only $platform with restored caches."
fi
