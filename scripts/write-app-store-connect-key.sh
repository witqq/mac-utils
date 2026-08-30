#!/bin/zsh
set -euo pipefail

private_key_base64="${APP_STORE_CONNECT_PRIVATE_KEY_BASE64:-}"
key_id="${APP_STORE_CONNECT_KEY_ID:-}"
runner_temp="${RUNNER_TEMP:-}"
github_env="${GITHUB_ENV:-}"

if [[ -z "$private_key_base64" || -z "$key_id" || -z "$runner_temp" || -z "$github_env" ]]; then
  print -u2 "APP_STORE_CONNECT_PRIVATE_KEY_BASE64, APP_STORE_CONNECT_KEY_ID, RUNNER_TEMP, and GITHUB_ENV are required."
  exit 1
fi
if [[ ! "$key_id" =~ ^[A-Z0-9]{10}$ ]]; then
  print -u2 "APP_STORE_CONNECT_KEY_ID must contain exactly 10 uppercase letters or digits."
  exit 1
fi

key_directory="$runner_temp/private_keys"
key_path="$key_directory/AuthKey_${key_id}.p8"
mkdir -p "$key_directory"
print -rn -- "$private_key_base64" | /usr/bin/base64 -D > "$key_path"
chmod 600 "$key_path"
if ! grep -q '^-----BEGIN PRIVATE KEY-----$' "$key_path" || ! grep -q '^-----END PRIVATE KEY-----$' "$key_path"; then
  print -u2 "Decoded App Store Connect key is not a PKCS#8 private key."
  rm -f "$key_path"
  exit 1
fi

print "APP_STORE_CONNECT_KEY_PATH=$key_path" >> "$github_env"
print "Prepared the App Store Connect API key in the ephemeral runner directory."
