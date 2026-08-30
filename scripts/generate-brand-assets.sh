#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source_root="$repo_root/Assets/Brand/source"
asset_root="$repo_root/Sources/MacUtilsApp/Resources/Assets.xcassets"
app_icon_root="$asset_root/AppIcon.appiconset"
menu_icon_root="$asset_root/MenuBarIcon.imageset"

command -v rsvg-convert >/dev/null || { print -u2 "rsvg-convert is required (brew install librsvg)."; exit 1; }
command -v sips >/dev/null || { print -u2 "sips is required."; exit 1; }

rsvg-convert --width 1024 --height 1024 "$source_root/app-icon.svg" --output "$app_icon_root/app-icon-1024.png"
for size in 16 32 64 128 256 512; do
  sips --resampleHeightWidth "$size" "$size" "$app_icon_root/app-icon-1024.png" \
    --out "$app_icon_root/app-icon-${size}.png" >/dev/null
done

rsvg-convert --width 18 --height 18 "$source_root/menu-bar-icon.svg" --output "$menu_icon_root/menu-bar-icon-18.png"
rsvg-convert --width 36 --height 36 "$source_root/menu-bar-icon.svg" --output "$menu_icon_root/menu-bar-icon-36.png"

print "Generated AppIcon (16–1024 px) and template menu bar icons (18/36 px)."
