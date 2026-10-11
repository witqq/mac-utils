# Privacy

[Русская версия](PRIVACY.ru.md)

Mac Utils is designed to work entirely on the Mac where it is installed.

## Data collection

Mac Utils does not collect, transmit, sell, or share personal data. The application contains no analytics SDK, advertising SDK, account system, telemetry client, or network client.

There is no developer-operated backend for the application.

## Data stored on the Mac

Mac Utils stores automation configuration, independent display preferences, selected-folder access, scan metadata and local display/storage diagnostics:

- script identifiers, names, and safe DSL source;
- global keyboard shortcut key codes and modifiers;
- stable CoreGraphics display UUIDs selected in script parameters;
- the selected application language in macOS user defaults.

Independent display history includes stable UUIDs, display names, relative bounds, roles, logical/pixel mode dimensions, refresh rate, mode identifiers and observed rotation. It is stored separately as `display-history.json` beside the automation configuration and is not sent anywhere.

The JSON configuration is stored in the user’s Application Support directory. In the Mac App Store build, macOS places it inside the application sandbox container. Writes use atomic replacement.

Mac Utils reads the current connected-display list and layout from macOS when displaying the UI or executing a display action. That information remains on the Mac.

Storage folder grants contain stable identifiers, current paths/names and scoped bookmarks in Application Support `storage-grants.json`. Dated JSON summaries in `Caches/com.witqq.mac-utils/storage-snapshots.json` retain at most twelve roots within 32 MiB. Full analyzed trees reside in adjacent private `storage-trees/<UUID>.sqlite` files, with `<UUID>.lease` and `.scans.lock` ownership/reader locks. Owner-only zero-byte `<UUID>.superseded` files record invalidated generations before Trash, preserving read-only protection after a restart even if JSON saving fails. They contain only the generation UUID in the filename. Safe disposal of an owned index removes its matching marker; standalone legacy markers can remain conservatively. This metadata includes names, parent IDs, directory paths, device/inode/birth identities, sizes/counts and cloud/link/incomplete/package flags; summaries also contain dates, capacity, ancestor proofs and analysis notes. It can reveal private names and paths and is not uploaded. Tree directories/files are owner-only (0700/0600). A soft 8 GiB budget removes whole inactive generations; active/newest indices take priority. Building checks a 512 MiB free-space reserve.

Scanning reads public filesystem catalog records or directory metadata, without opening regular file contents or following symlinks. Synchronous scan metadata operations disable cloud-placeholder materialization through the worker thread's I/O policy and restore its previous policy afterward; they fail if protection cannot be enabled. Catalog mode identifies cloud placeholders through native dataless flags and blocked metadata I/O, without querying legacy iCloud downloading status. Native Finder reveal and Trash operate only on user-selected items; Trash requires confirmation and current identity/path checks. The app does not automatically classify junk, empty Trash or purge system caches.

Choose Disk reads visible mounted-volume names, paths and capacity; Choose Folder remains separate. Supported APFS roots use public catalog queries with verified startup System/Data mappings. The shared persistent tree includes accepted descendants and package internals. Expansion, paging, sibling sorting and map focus read that index rather than rescan source metadata. Refresh is explicit. Catalog coverage remains unverified even with no errors; the latest full tree is saved and a previous complete result retained separately. Older full-tree caches remain readable; compact overviews require explicit refresh to build a tree. The app's entire own analysis-tree cache is excluded with a note. Successful Trash creates a revised copy-on-write generation of that private index, masks moved subtrees and adjusts known totals without scanning source files. Surviving IDs, original date and coverage remain. Format-2 masked records can retain moved names/metadata inside the private database until saved results are cleared; this metadata is not a copy of file contents. A successful primary revision is saved, while affected prior backups and other overlapping results are invalidated.

## Permissions

The Mac App Store build uses App Sandbox. Native global hotkeys and CoreGraphics display configuration were verified in a sandboxed local build without an Accessibility permission request.

Storage uses a native folder/volume selection panel. The Store build has user-selected read/write and app-scoped bookmark entitlements; access is balanced on the selected/resolved URL and must be renewed by selecting the folder again if expired. macOS privacy-denied paths remain inaccessible; a catalog can also omit protected entries without an explicit error. Signed live Store folder-access behavior has not yet been verified locally.

**Disk Access…** explains optional Full Disk Access and can open **System Settings → Privacy & Security → Full Disk Access**. This broad permission includes other apps' private data and must be enabled by the user; Mac Utils does not grant it automatically or probe private files to certify it. The sheet shows the app path and can copy that path to the clipboard at the user's request. Full Disk Access does not replace Store selection grants or prove catalog completeness. Mac Utils does not request Contacts, Calendars, Photos, Camera, Microphone, Location, Screen Recording or Automation access for these features.

## Diagnostics

Display reads and transitions produce local JSON-line diagnostics containing display names, stable/runtime identifiers, bounds, rotation, modes, mirror membership, planned operations, native mode catalogs and CoreGraphics outcomes. Records carry timestamps and session/transition correlation identifiers. The log directory is created with owner-only access and log files with owner-only read/write permissions. The current log rotates to one previous file around a 2,000,000-byte threshold; a complete individual record is retained.

Logs reside under the app's user Library at `Logs/com.witqq.mac-utils/displays.jsonl` and `displays.previous.jsonl`, inside the container for the App Store build. They are not uploaded. Explicit diagnostic flags can additionally print display information, configuration counts and status values to the invoking terminal. [Support](SUPPORT.md) explains how to inspect these files and commands before choosing what to share.

Storage analysis writes `storage.jsonl` and one `storage.previous.jsonl` in the same directory. Records contain scan/session identifiers, timestamps, selected/last processed paths, phases, counts, sizes, elapsed time, average rate, cache disposition and errors. A two-second heartbeat preserves the latest path during a stall; there is no per-file log. Each file is limited to 2,000,000 bytes, with oversized details replaced by a truncation marker. The directory uses owner-only access and files owner-only read/write. Trash events also record selected/moved/failure counts, changed paths, revision UUID and index/cache-write warnings. Paths/errors can reveal private metadata: inspect and redact records before sharing. The app does not upload them; public OSLog scan events contain event/scan identifiers rather than paths.

## Removing local data

Delete scripts and shortcuts in the application before uninstalling. To remove all remaining configuration, delete the Mac Utils Application Support data or the sandbox container through macOS after quitting the application.

To remove display history, delete `display-history.json` from that Application Support directory. To remove retained diagnostics, delete the app's `Logs/com.witqq.mac-utils` directory after quitting Mac Utils and any diagnostic watcher. The next display session can create fresh history and logs.

In Storage, **Manage** explains each operation beside its button. Confirmed **Remove Saved Scan Results…** removes summaries and unused tree generations but retains folder grants. **Remove This Saved Location** removes its bookmark and saved results. Confirmed **Reset Saved Locations…** forgets all storage grants/results. Active readers defer index removal until released when results are replaced or the window closes. These operations do not delete scanned files, scripts/display history or alter macOS privacy permissions. After quitting, remove `storage-grants.json` from Application Support and `storage-snapshots.json` plus the app's `storage-trees` directory from Caches to remove the same metadata.

The exact public support instructions and App Store privacy declaration will remain aligned with this behavior. If a future version adds any network or data-processing feature, this document and the App Store disclosure must be updated before release.

Privacy questions can be submitted through the process in [Support](SUPPORT.md).
