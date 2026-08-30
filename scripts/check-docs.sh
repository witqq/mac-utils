#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

typeset -i failures=0
markdown_files=("${(@f)$(git ls-files --cached --others --exclude-standard -- '*.md')}")
for file in "${markdown_files[@]}"; do
    while IFS= read -r raw_target; do
        target="${raw_target#??}"
        target="${target%%#*}"
        case "$target" in
            ""|http://*|https://*|mailto:*|app://*)
                continue
                ;;
        esac
        candidate="${file:h}/$target"
        if [[ ! -e "$candidate" ]]; then
            print -u2 "Broken internal link: $file -> $target"
            failures+=1
        fi
    done < <(grep -Eo '\]\([^)]+' "$file" || true)
done

for file in .github/ISSUE_TEMPLATE/*.yml .github/release.yml; do
    ruby -e 'require "yaml"; YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)' "$file"
done

plutil -lint \
    Sources/MacUtilsApp/Resources/en.lproj/Localizable.strings \
    Sources/MacUtilsApp/Resources/ru.lproj/Localizable.strings >/dev/null

if (( failures > 0 )); then
    exit 1
fi

print "Documentation links, YAML, and localization resources are valid."
