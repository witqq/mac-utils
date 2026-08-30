#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
tag="${1:-}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  print -u2 "Release tag must match vMAJOR.MINOR.PATCH; received: $tag"
  exit 1
fi

version="${tag#v}"
configured_version="$(ruby -e 'text = File.read(ARGV.fetch(0)); match = text.match(/^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$/); abort "MARKETING_VERSION not found" unless match; puts match[1]' "$repo_root/project.yml")"
if [[ "$version" != "$configured_version" ]]; then
  print -u2 "Tag version $version does not match project MARKETING_VERSION $configured_version."
  exit 1
fi

notes="$repo_root/docs/releases/$tag.md"
[[ -s "$notes" ]] || { print -u2 "Missing release notes: $notes"; exit 1; }
print "$version"
