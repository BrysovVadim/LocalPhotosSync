#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
swift build
binary_dir="$(swift build --show-bin-path)"
app_dir="$project_root/.build/LocalPhotosSync USB.app"
build_id="$(uuidgen)"
staging_root="$project_root/.build/app-staging-$build_id"
staging_app="$staging_root/LocalPhotosSync USB.app"
previous_parent="$project_root/.build/previous-apps"
previous_app="$previous_parent/$build_id.app"
mkdir -p "$previous_parent"
mkdir "$staging_root"
mkdir -p "$staging_app/Contents/MacOS"
cp "$binary_dir/LocalPhotosSyncUSB" "$staging_app/Contents/MacOS/LocalPhotosSyncUSB"
cp "$project_root/Resources/Info.plist" "$staging_app/Contents/Info.plist"
mkdir -p "$staging_app/Contents/Resources"
iconset="$staging_root/AppIcon.iconset"
mkdir "$iconset"
icon_source="$project_root/Resources/AppIcon/AppIcon-1024.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$(( size * 2 ))
    sips -z $double $double "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$staging_app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"
codesign --force --sign - --options runtime --entitlements "$project_root/Resources/Entitlements.plist" "$staging_app"
codesign --verify --deep --strict "$staging_app"

previous_archived=0
if [[ -e "$app_dir" || -L "$app_dir" ]]; then
    mv "$app_dir" "$previous_app"
    previous_archived=1
fi

if mv "$staging_app" "$app_dir"; then
    if (( previous_archived )); then
        print -u2 -r -- "Previous app preserved at: $previous_app"
    fi
else
    if (( previous_archived )); then
        if [[ -e "$app_dir" || -L "$app_dir" ]]; then
            failed_parent="$project_root/.build/failed-apps"
            failed_app="$failed_parent/$build_id.app"
            mkdir -p "$failed_parent"
            mv "$app_dir" "$failed_app"
            print -u2 -r -- "Failed publication preserved at: $failed_app"
        fi
        if mv "$previous_app" "$app_dir"; then
            print -u2 -r -- "Restored previous app from: $previous_app" >&2
        else
            print -u2 -r -- "Could not restore previous app; preserved at: $previous_app" >&2
            exit 1
        fi
    fi
    print -u2 -r -- "Could not publish staged app; staged bundle preserved at: $staging_app"
    exit 1
fi
print -r -- "$app_dir"
