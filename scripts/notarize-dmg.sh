#!/bin/zsh
set -euo pipefail

dmg_path="${1:-}"
shift || true
if [[ ! -f "$dmg_path" || "$dmg_path" != *.dmg ]]; then
  print -u2 "Usage: $0 /path/to/Mac-Utils-v1.0.0.dmg [notarytool-profile | --key path --key-id id --issuer uuid]"
  exit 1
fi

notary_arguments=()
if [[ "${1:-}" == "--key" ]]; then
  if (( $# != 6 )) || [[ "${3:-}" != "--key-id" || "${5:-}" != "--issuer" ]]; then
    print -u2 "API authentication requires: --key path --key-id id --issuer uuid"
    exit 1
  fi
  notary_arguments=(--key "$2" --key-id "$4" --issuer "$6")
else
  profile="${1:-mac-utils-notary}"
  notary_arguments=(--keychain-profile "$profile")
fi

codesign --verify --verbose=4 "$dmg_path"
xcrun notarytool history "${notary_arguments[@]}" --output-format json >/dev/null
xcrun notarytool submit "$dmg_path" "${notary_arguments[@]}" --wait
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
