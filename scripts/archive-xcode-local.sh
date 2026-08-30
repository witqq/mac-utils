#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

mode="${1:-}"
case "$mode" in
    direct)
        scheme="MacUtils-Direct"
        archive_name="MacUtils-Direct"
        export_options="Config/ExportOptions/Direct.plist"
        ;;
    app-store)
        scheme="MacUtils-AppStore"
        archive_name="MacUtils-AppStore"
        export_options="Config/ExportOptions/AppStore.plist"
        ;;
    *)
        print -u2 "Usage: $0 direct|app-store"
        exit 1
        ;;
esac

./scripts/generate-xcode-project.sh
archive_path=".build/xcode-archives/$archive_name.xcarchive"
export_path=".build/xcode-exports/$mode"
if [[ -e "$archive_path" || -e "$export_path" ]]; then
    print -u2 "Refusing to overwrite an existing signed artifact. Move or remove:"
    print -u2 "  $archive_path"
    print -u2 "  $export_path"
    exit 1
fi
mkdir -p .build/xcode-archives .build/xcode-exports

xcodebuild archive \
    -quiet \
    -project MacUtils.xcodeproj \
    -scheme "$scheme" \
    -destination "generic/platform=macOS" \
    -derivedDataPath ".build/xcode-derived-archive-$mode" \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates

xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options" \
    -allowProvisioningUpdates

print "Signed archive: $archive_path"
print "Distribution export: $export_path"
