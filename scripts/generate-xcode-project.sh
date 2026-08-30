#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    print -u2 "XcodeGen 2.46.0 or newer is required: brew install xcodegen"
    exit 1
fi

autoload -Uz is-at-least
version="$(xcodegen --version | awk '{print $2}')"
if ! is-at-least 2.46.0 "$version"; then
    print -u2 "XcodeGen 2.46.0 or newer is required; found $version"
    exit 1
fi

xcodegen generate --spec project.yml
