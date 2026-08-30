#!/bin/zsh
set -euo pipefail

repo_root="${MAC_UTILS_REPO_ROOT:-${0:A:h:h}}"
app_path="${1:-}"
output_path="${2:-}"
signing_identity="${3:-}"
background="$repo_root/Assets/Brand/dmg/background.png"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  print -u2 "Usage: $0 /path/to/Mac\\ Utils.app /path/to/Mac-Utils-v1.0.0.dmg [signing-identity]"
  exit 1
fi
if [[ -z "$output_path" || "$output_path" != *.dmg ]]; then
  print -u2 "Output must be an explicit .dmg path."
  exit 1
fi
if [[ -e "$output_path" ]]; then
  print -u2 "Refusing to overwrite existing output: $output_path"
  exit 1
fi
[[ -s "$background" ]] || { print -u2 "Missing DMG background: $background"; exit 1; }

temp_root=$(mktemp -d "${TMPDIR%/}/mac-utils-dmg.XXXXXX")
staging="$temp_root/staging"
mount_point="$temp_root/mount"
read_write_image="$temp_root/Mac-Utils-rw.dmg"
mounted=false

cleanup() {
  if [[ "$mounted" == true ]]; then hdiutil detach "$mount_point" -quiet || true; fi
  rm -rf "$temp_root"
}
trap cleanup EXIT

mkdir -p "$staging/.background" "$mount_point" "${output_path:h}"
ditto "$app_path" "$staging/Mac Utils.app"
ln -s /Applications "$staging/Applications"
cp "$background" "$staging/.background/background.png"

hdiutil create -quiet -volname "Mac Utils" -srcfolder "$staging" -format UDRW "$read_write_image"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$mount_point" "$read_write_image"
mounted=true
osascript "$repo_root/scripts/dmg-layout.applescript" "$mount_point"
sync
hdiutil detach "$mount_point" -quiet
mounted=false
hdiutil convert -quiet "$read_write_image" -format UDZO -imagekey zlib-level=9 -o "$output_path"
if [[ -n "$signing_identity" ]]; then
  codesign --force --timestamp --sign "$signing_identity" "$output_path"
fi

print "Created $output_path"
