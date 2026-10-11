# Mac Utils user guide

[Русская версия](USER_GUIDE.ru.md)

Mac Utils runs from the macOS menu bar. Its shared utility window analyzes storage and manages scripts, shortcuts, settings and help. A sequence of registered actions becomes a reusable script that one global shortcut runs from any application.

## Requirements and installation

Mac Utils requires macOS 26 or later.

Download the notarized Direct build from the [latest GitHub release](https://github.com/witqq/mac-utils/releases/latest), open the DMG, and drag **Mac Utils** to **Applications**. The Mac App Store build is awaiting Apple publication; its product link will be added afterward.

Developers can run `./scripts/run.sh` from a source checkout. This guide describes the current source, including storage analysis under development; consult the downloaded release's notes for the features available in that published build.

## First launch

Mac Utils has no Dock icon. Find the overlapping-displays icon in the menu bar.

1. Open the menu bar item.
2. Select **Settings…**.
3. Read the onboarding cards or open the **Help** tab.
4. Choose **Language → System**, **English**, or **Русский**. The choice applies only to Mac Utils unless **System** is selected.

Use the sidebar to switch between **Storage**, **Scripts**, **Shortcuts**, **General** and **Help**. The minimum content size is 960×720 points. Resize the window or choose **Window → Toggle Full Screen** (Control-Command-F). The menu-bar **Analyze Storage…** button selects Storage even when the window is already open.

Pause the pointer over buttons and menu items for explanations of their effects. Controls also expose accessibility help. This includes display commands, script steps and their parameters, shortcut recording, storage management and the native Edit/Window menus. **Close Window** keeps Mac Utils running in the menu bar; **Quit** stops its global shortcuts until the app is reopened.

## Analyze and clean storage

1. Choose **Analyze Storage…** in the menu bar, then **Choose Disk** for a named mounted volume. The startup root `/` appears by its macOS name; hidden implementation volumes are excluded. **Choose Folder…** (Command-O) selects a smaller area. A location with saved results opens its dated tree without scanning. Choosing a disk/folder without saved results starts initial analysis; switching to an already saved list entry without results waits for **Scan**. If loading an index reports an error, use explicit **Refresh**; the error does not start a scan. If macOS requests folder access, confirm the disk root there.
2. Use **Refresh** (Command-R) for a fresh scan. Progress identifies the current phase: preparation, directory traversal, catalog reading or catalog-result validation. It also shows elapsed time, processed objects, average rate, counted sizes and the latest path. When the volume reports an object-count estimate, catalog progress shows an explicitly approximate percentage below 100%; validation still follows it. Folder traversal has no reliable percentage. **Cancel** or Escape stops the scan and keeps the previous result, if one exists.
3. Choose **Logical size** or **Allocated**. Logical size measures file lengths; allocated size comes from filesystem allocation metadata. Sparse files can have very different values. Hard-link contributions count once within the selected root; duplicate paths show their apparent size in the selection details.
4. In **Tree**, use disclosure arrows to expand folders and packages in place. Each branch loads 200 saved children at a time; **Show More · N remaining** loads the next page. Choose **Largest First** or **Smallest First** to sort siblings by the selected size metric. Columns show logical size, allocated size and share of the analyzed root. Double-click a folder/package, choose **Open Folder**, or use breadcrumbs to focus that branch and its map. These operations read saved metadata, without rescanning files. **Largest files** shows up to 200 files and whole packages from the analyzed root. **Size Map** is hidden initially; enable it and drag the divider to resize the tree and map. The focused-folder map shows up to 255 positive-size children from loaded pages plus a gray **Remaining items** sum; omitted tiles remain reachable through the tree. Zero-size items have no tile. The gray sum cannot be selected for deletion. **Folder in Finder** opens the focused ordinary directory.
5. Select an item and choose **Show in Finder** to reveal the first selected item, or select items and choose **Move to Trash**. Package contents are browsable but cannot be moved separately: select the whole package. Confirmation lists full paths in a scrollable area with fixed Cancel/Trash buttons. The app checks canonical saved-tree membership and current root, item and ancestor identity; it rejects the scan root, protected system/home paths and its own analysis cache or ancestors. Failures appear in **Details**. Replaced/moved items require another scan. Successful moves remove only the moved subtrees from the saved analysis and adjust known sizes/counts without rescanning. Expanded branches, loaded pages, size/order/map choices and surviving selections stay available. If the focused folder was moved, focus goes to its nearest surviving ancestor. Other overlapping saved locations are invalidated. Trash does not immediately free space; emptying it remains a separate Finder operation.

After Trash, the original scan date and coverage warning remain: the app subtracts known moved contributions, rather than claiming a fresh measurement. Unrelated changes still need **Refresh**. Partial success keeps failed items available. If the private index cannot be revised, a warning leaves the historical browser open, hides known moved items and disables more Trash until Refresh. If only saving the revision fails, the updated tree remains usable in this session, but may not survive restart. If restart opens the older saved result, its historical list may still show moved objects. It is marked read-only and requires explicit Refresh before more Trash. Durable protection is recorded before native moves; if it cannot be saved, no items are moved. Files already moved are in Finder's Trash; neither warning undoes that operation. Revising the cache requires native cloning support; first use of an older tree can take time to build metadata indices without reading source files.

Volume free space and capacity are separate from the selected folder's totals. APFS files can share blocks, so allocated sums do not measure exclusive occupied or reclaimable space. Supported APFS volume roots read the public filesystem catalog; startup analysis combines verified System/Data mappings without double-counting their aliases. Folders and explicitly unsupported catalogs use directory traversal with batched metadata where available. Unrelated mounted volumes, symlink targets and cloud-only directory contents are excluded. Scanning does not open file contents and disables cloud-placeholder materialization for its synchronous metadata operations.

Catalog results always warn that protected-area coverage is unverified, even without reported skips: the system can silently omit protected records. **Analysis notes: N** opens reported notes. N counts notes rather than missing files; one folder note can concern many files, and the list is not a complete inventory of inaccessible data. The app's own tree cache is intentionally excluded and produces a note. Use **Disk Access…** or choose a smaller folder and repeat analysis. A full tree retains the objects included in that analysis; it does not certify access to all disk data. If the catalog confirms a file was replaced at an already accepted path, the first historical size remains counted once, the newer version is omitted and an analysis note marks the affected branch incomplete. Refresh is needed for its current size; cleanup refuses the replaced identity. Unsafe directory changes and other unrecognized identity/catalog errors still stop the scan instead of silently switching methods. Results are historical, and scan duration varies with contents and access.

Expanding, paging, sorting, selecting a map tile and focusing a folder use the same saved tree and scan date. **Refresh** rescans the selected saved disk/folder root, including when a nested branch is focused. Reopening that location restores its latest result. Older full-tree caches remain browsable; an older compact overview displays a message requiring one explicit Refresh to build the tree. Opening a folder never starts that refresh automatically.

**Manage** explains each action beside its button. **Remove This Saved Location** removes that location, bookmark and saved results. Confirmed **Remove Saved Scan Results…** removes results but keeps access; confirmed **Reset Saved Locations…** also forgets bookmarks and requires reselection. These actions change app metadata, not scanned files or macOS privacy permissions. Active tree readers protect their index until released; the utility releases them when results are replaced or the window closes. A failed/cancelled replacement keeps usable results. A completed new full tree becomes the latest saved result even with unverified catalog coverage; an earlier complete result remains a separate backup.

The JSON summary retains at most twelve roots within 32 MiB. Full tree databases are stored separately in the app's private cache, with a soft 8 GiB budget that removes whole inactive generations. Active/newest indices take priority over this budget. Building stops if it cannot maintain 512 MiB of available space. An oversized summary can remain visible without being saved. While replacing an analysis, a cache-write failure reports an error and preserves the previous result. These limits do not truncate a successfully published tree's child list.

Folder access uses native selection and saved bookmarks. If access expires, choose the folder again. After a supported bookmarked folder move, fresh analysis updates its name/path while preserving grant identity; historical cleanup at a moved root is refused. macOS privacy restrictions still apply. Store access is limited to selected-folder grants; signed live Store access remains unverified locally.

**Disk Access…** explains how to reduce separate protected-folder requests through optional Full Disk Access. It is a broad macOS permission, including other apps' private data; decide whether to enable it yourself in **System Settings → Privacy & Security → Full Disk Access**. The sheet shows the app path, offers **Copy App Path**, and **Open Access Settings…** stops any active scan before opening that page. If navigation fails, follow the displayed manual route. Enable Mac Utils, adding the shown application with **+** if absent; follow any macOS request to quit and reopen it, then choose **Repeat Analysis**. The app does not grant or certify the permission by opening private files. Some system paths can remain protected, and Store still needs its native disk/folder selection grant.

Local scan diagnostics record phase, last path/count/rate, elapsed time, cache decisions and errors in bounded `storage.jsonl`/`storage.previous.jsonl`. Nothing is uploaded automatically; see [Support](SUPPORT.md) before sharing private paths.

The **macOS Storage…**, **Downloads** and **Open Trash** buttons open native management surfaces. For recommendations use **System Settings → General → Storage** if the shortcut does not navigate there. Review macOS recommendations and Trash yourself; Mac Utils does not classify global junk or run automatic cache purges.

## Launch at login

Open **Settings… → General** and turn on **Launch Mac Utils at login**. Mac Utils uses the public macOS Login Items service and changes this setting only when you use the switch.

The status shown below the switch is read from macOS. If approval is required, select **Open Login Items…**, allow Mac Utils in **System Settings → General → Login Items & Extensions**, return to Mac Utils, and select **Refresh Status**. Turning the switch off unregisters the app; it does not quit the current process.

## Display terms

- **Main display** contains the menu bar and establishes the origin of the desktop layout.
- **Extended display** adds separate desktop space.
- **Mirror** shows the content of another display. macOS can give both members a shared mode and layout. When they become independent, Mac Utils restores their remembered supported modes and relative positions, including the former source. A source with remaining mirrors keeps its shared mode.
- **Toggle by State** reads a current value. It runs **Then** when the value matches and **Otherwise** when it does not.

The menu bar popover lists each connected display, its current role, and resolution. Its **Main**, **Extend**, and **Mirror** controls execute the same registered actions used by scripts. The popover opens under the menu bar icon and closes when you press Escape, select the icon again, or click anywhere outside it.

Before using a mirror/extend toggle, set the desired independent arrangement, scaling, refresh rate and rotation in **System Settings → Displays**, then refresh Mac Utils. It remembers independent displays by stable UUID across restarts. Changing the main display translates the arrangement while preserving left/right relationships and vertical offsets. If no independent history exists, a newly extended display is placed to the right. An unavailable saved mode falls back to the panel's supported default/native mode compatible with its current rotation; if neither is available, macOS's current mode remains. Mac Utils does not set rotation: a saved/current rotation mismatch requires correction in Displays settings. With the checked Odyssey G61SD main display and portrait G27Q on its right, both mirror directions returned to the original independent modes and arrangement; the user confirmed the complete portrait image without cropping and correct right-side placement. Other hardware and arrangements require their own verification.

## Build a script visually

1. Open **Settings… → Scripts**.
2. Select **+** and enter a descriptive name.
3. Select **Add Step** and choose an action or a **Toggle by State** provider.
4. Choose displays by their macOS names. Mac Utils stores their stable CoreGraphics identifiers.
5. Reorder steps with the arrow buttons or drag and drop. A step can also be duplicated or deleted.
6. Select **Validate** to check every action, parameter, and nested branch.
7. Select **Save**.

Deleting a script requires confirmation and also removes its shortcut assignments. Deleting a draft builder step requires a separate confirmation.

## Mirror/extend toggle recipe

Create one **Toggle by State → Display Mode** step:

- **Display:** the secondary display.
- **When state is:** **Mirror**.
- **Then:** **Extend display** with the same secondary display.
- **Otherwise:** **Mirror display** with the secondary display as **Display** and the main display as **Source**.

This is a universal state-driven toggle: it reads the live display state every time instead of remembering which branch ran previously.

## Assign and edit a global shortcut

1. Open **Settings… → Shortcuts**.
2. Choose a saved script.
3. Select **Record Shortcut** and press a key with Control, Option, or Command. Escape cancels recording.
4. Select **Assign**.

One shortcut runs every step in its script in order. To change it, select **Edit**, record a replacement, and select **Save Change**. Mac Utils registers the replacement before removing the previous assignment. If macOS or another in-app binding rejects the replacement, the previous shortcut remains active.

Removing a shortcut requires confirmation but does not delete its script.

## Refresh Universal Control in Direct builds

Keep the Magic Trackpad connected to its normal host Mac and use Apple's Universal Control to control the second Mac. Mac Utils does not pair, disconnect, or transfer the trackpad.

The Direct build provides a local recovery action for cases where Universal Control stops responding:

1. Open **Settings… → Scripts**, create a script, and select **Add Step**.
2. Add **Refresh Universal Control**. The action has no parameters.
3. Save the script, open **Shortcuts**, and assign a global key combination.
4. Press the shortcut on the Mac whose Universal Control connection needs recovery. If necessary, configure and run the same local script on the other Mac.

The action restarts a fixed set of local Continuity processes and lets macOS reconnect them. It can briefly interrupt Universal Control, Handoff, AirDrop, Sidecar, or Universal Clipboard activity. It does not change Apple Account settings or Bluetooth pairing and cannot guarantee recovery when macOS requirements or network conditions are not satisfied.

This action is absent from the Mac App Store build because sandboxed applications cannot perform this process-control operation. The [feasibility report](MAGIC_TRACKPAD_FEASIBILITY.md) explains the supported trackpad arrangement and boundaries.

## Dismiss all notifications in Direct builds

The Direct build provides an action that closes every visible Notification Center banner and alert, including alerts that stay on screen until they are closed by hand (for example, new-mail alerts) and the stacks macOS builds from repeated notifications of one application:

1. Open **Settings… → Scripts**, create a script, and select **Add Step**.
2. Add **Dismiss all notifications**. The action has no parameters.
3. Save the script, open **Shortcuts**, and assign a global key combination.
4. Press the shortcut whenever notifications cover the screen.

The action needs Accessibility access. On the first run macOS shows a system prompt; allow Mac Utils in **System Settings → Privacy & Security → Accessibility** and run the action again. Until access is granted the action closes nothing. Because a script started by a global shortcut reports no failure inside Mac Utils, that system prompt is the only visible sign that access is missing.

Mac Utils performs only the Notification Center's own **Close** and **Clear All** actions, using their names in every system language. A stack is removed as a whole by its **Clear All** action, so it counts as one dismissed item. It does not open notifications, read their content, or change notification settings. The action is absent from the Mac App Store build because sandboxed applications cannot control other applications through Accessibility.

## Optional DSL editor

The visual builder is the recommended editor. **DSL Text** exposes the same safe scenario representation for advanced users. It does not evaluate expressions, access files, launch processes, or run shell code.

One action is written per line with quoted named parameters:

```text
extend-display display="SECONDARY-DISPLAY-UUID"
```

A state toggle uses explicit blocks:

```text
@toggle provider="display.mode" equals="mirror" display="SECONDARY-DISPLAY-UUID"
  @match
    extend-display display="SECONDARY-DISPLAY-UUID"
  @otherwise
    mirror-display display="SECONDARY-DISPLAY-UUID" source="MAIN-DISPLAY-UUID"
@end
```

Comments begin with `#`. Switching back to the visual builder is allowed only after the entire text parses and validates, so invalid text cannot replace the last valid visual model.

## Local data and recovery

Configuration is stored as JSON under the application’s Application Support directory. The App Store build receives the normal sandbox container path automatically. Writes are atomic.

Independent display preferences are saved separately in `display-history.json` beside `configuration.json`. If history is partial, restoring positions requires the remembered position of the current main display as a shared reference; otherwise deterministic placement is used, while available saved modes can still return. Display diagnostics stay in the app's local Library/Logs directory; see [Support](SUPPORT.md) for access. A failed history save after a display change means the change applied, but its preferences may not survive a restart.

Do not edit the file while Mac Utils is running. If JSON or schema validation fails, Mac Utils starts with a safe empty configuration and shows the error. A saved script or shortcut that cannot currently activate remains visible so it can be corrected or removed without silent data loss.

## Troubleshooting

- **A display is missing:** reconnect it, then select the refresh button in the menu bar popover.
- **A mirrored display has a generic name:** extend it once so macOS exposes its localized name again. Its stable identifier remains unchanged.
- **Window positions change after a display script runs:** macOS re-lays out windows whenever display roles or positions change. Mac Utils does not save or restore window positions.
- **A shortcut is unavailable:** record a different combination. The existing shortcut remains active during a failed edit.
- **A script does not validate:** read the localized line and column message, or switch to the visual builder after correcting the DSL.
- **The UI does not appear in the Dock:** this is expected; Mac Utils is a menu bar accessory application.
- **Launch at login needs approval:** use the button in **Settings… → General** to open Login Items, allow Mac Utils, then refresh the displayed status.
- **Notifications are not dismissed:** allow Mac Utils under Accessibility in System Settings, then run the action again. After a macOS update that changes the Notification Center layout, the action may stop finding notifications until Mac Utils is updated.
- **Universal Control does not reconnect after refresh:** confirm Apple's Universal Control requirements and settings on both Macs, then try the local refresh shortcut on each Mac. The action does not alter pairing or account configuration.

See [Known limitations](KNOWN-LIMITATIONS.md) and [Support](SUPPORT.md) for confirmed constraints and reporting instructions.

When a new utility becomes user-facing, its workflow, limitations, screenshots, download links, and App Store availability must also be reflected in this guide and on the product landing page before release.
