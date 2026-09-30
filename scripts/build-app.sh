#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
swift build
binary_dir="$(swift build --show-bin-path)"
app_dir="$project_root/.build/LocalPhotosSync USB.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/LocalPhotosSyncUSB" "$app_dir/Contents/MacOS/LocalPhotosSyncUSB"
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$project_root/Resources/Entitlements.plist" "$app_dir"
print -r -- "$app_dir"
