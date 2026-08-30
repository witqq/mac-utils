#!/bin/zsh
set -euo pipefail

certificate_base64="${APPLE_CERTIFICATE_BASE64:-}"
certificate_password="${APPLE_CERTIFICATE_PASSWORD:-}"
runner_temp="${RUNNER_TEMP:-}"
github_env="${GITHUB_ENV:-}"

if [[ -z "$certificate_base64" || -z "$certificate_password" || -z "$runner_temp" || -z "$github_env" ]]; then
  print -u2 "APPLE_CERTIFICATE_BASE64, APPLE_CERTIFICATE_PASSWORD, RUNNER_TEMP, and GITHUB_ENV are required."
  exit 1
fi

certificate_path="$runner_temp/mac-utils-signing.p12"
keychain_path="$runner_temp/mac-utils-signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"

print -rn -- "$certificate_base64" | /usr/bin/base64 -D > "$certificate_path"
chmod 600 "$certificate_path"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" \
  -k "$keychain_path" \
  -P "$certificate_password" \
  -A \
  -t cert \
  -f pkcs12 >/dev/null
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_password" \
  "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path"
rm -f "$certificate_path"

print "MAC_UTILS_KEYCHAIN_PATH=$keychain_path" >> "$github_env"
print "Imported the signing identity into an ephemeral CI keychain."
