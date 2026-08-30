#!/bin/zsh
set -euo pipefail

dmg_path="${1:-}"
profile="${2:-mac-utils-notary}"
if [[ ! -f "$dmg_path" || "$dmg_path" != *.dmg ]]; then
  print -u2 "Usage: $0 /path/to/Mac-Utils-v1.0.0.dmg [notarytool-profile]"
  exit 1
fi

codesign --verify --verbose=4 "$dmg_path"
xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null
xcrun notarytool submit "$dmg_path" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
codesign --verify --verbose=4 "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
hdiutil verify "$dmg_path"

checksum_path="$dmg_path.sha256"
(
  cd "${dmg_path:h}"
  shasum -a 256 "${dmg_path:t}" > "${checksum_path:t}"
  shasum -a 256 -c "${checksum_path:t}"
)
print "Checksum: $checksum_path"
