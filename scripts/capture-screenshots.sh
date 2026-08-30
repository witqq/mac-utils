#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
derived_data="$repo_root/agent_temp_files_local/screenshot-derived-data"
app="$derived_data/Build/Products/Release-AppStore/Mac Utils.app/Contents/MacOS/Mac Utils"

"$repo_root/scripts/generate-xcode-project.sh"
xcodebuild \
  -project "$repo_root/MacUtils.xcodeproj" \
  -scheme MacUtils-AppStore \
  -configuration Release-AppStore \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

capture() {
  local language="$1"
  local locale="$2"
  local fixture="$3"
  local name="$4"
  shift 4
  local output="$repo_root/Assets/Screenshots/raw/$locale/$name.png"
  "$app" \
    --open-settings \
    --screenshot-fixture \
    --ui-language "$language" \
    --configuration-file "$repo_root/Assets/Screenshots/fixtures/$fixture" \
    --capture-ui "$output" \
    "$@"
  [[ -s "$output" ]] || { print -u2 "Screenshot was not created: $output"; exit 1; }
}

for capture_spec in \
  "english en configuration-en.json" \
  "russian ru configuration-ru.json"; do
  read -r language locale fixture <<< "$capture_spec"
  capture "$language" "$locale" "$fixture" 01-builder --skip-onboarding --settings-tab scripts
  capture "$language" "$locale" "$fixture" 02-shortcuts --skip-onboarding --settings-tab shortcuts
  capture "$language" "$locale" "$fixture" 03-help --skip-onboarding --settings-tab help
  capture "$language" "$locale" "$fixture" 04-onboarding --show-onboarding --settings-tab scripts
  capture "$language" "$locale" "$fixture" 05-general --skip-onboarding --settings-tab general
done

"$repo_root/scripts/compose-marketing-assets.sh"
