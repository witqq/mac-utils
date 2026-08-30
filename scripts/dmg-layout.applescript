on run arguments
    set mountPath to item 1 of arguments
    set volumeFolder to POSIX file mountPath as alias
    tell application "Finder"
        open volumeFolder
        set volumeWindow to container window of volumeFolder
        set current view of volumeWindow to icon view
        set toolbar visible of volumeWindow to false
        set statusbar visible of volumeWindow to false
        set pathbar visible of volumeWindow to false
        set bounds of volumeWindow to {100, 100, 820, 580}
        set viewOptions to icon view options of volumeWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 14
        set background picture of viewOptions to file ".background:background.png" of volumeFolder
        set position of item "Mac Utils.app" of volumeFolder to {180, 270}
        set position of item "Applications" of volumeFolder to {540, 270}
        update volumeFolder without registering applications
        delay 2
        close volumeWindow
    end tell
end run
