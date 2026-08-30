#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
ruby "$repo_root/scripts/check-release-assets.rb"

if [[ -x "$repo_root/scripts/check-landing.sh" ]]; then
  "$repo_root/scripts/check-landing.sh"
fi
