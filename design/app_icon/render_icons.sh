#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_svg="$script_dir/sticky-panel-flat.svg"
mac_iconset="$repo_root/macos/Runner/Assets.xcassets/AppIcon.appiconset"
windows_ico="$repo_root/windows/runner/resources/app_icon.ico"
render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT

sips -s format png "$source_svg" --out "$render_dir/app-icon-1024.png" >/dev/null

for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$render_dir/app-icon-1024.png" \
    --out "$mac_iconset/app_icon_${size}.png" >/dev/null
done

ffmpeg -y -hide_banner -loglevel error \
  -i "$render_dir/app-icon-1024.png" \
  -filter_complex \
  '[0:v]split=7[s16][s24][s32][s48][s64][s128][s256];[s16]scale=16:16[v16];[s24]scale=24:24[v24];[s32]scale=32:32[v32];[s48]scale=48:48[v48];[s64]scale=64:64[v64];[s128]scale=128:128[v128];[s256]scale=256:256[v256]' \
  -map '[v16]' -map '[v24]' -map '[v32]' -map '[v48]' \
  -map '[v64]' -map '[v128]' -map '[v256]' \
  -c:v png "$windows_ico"

echo "Rendered macOS fallback icons and Windows ICO."
