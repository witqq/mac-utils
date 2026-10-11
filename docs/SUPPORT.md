# Support

[Русская версия](SUPPORT.ru.md)

## Start here

1. Read the built-in **Help** tab.
2. Check the [User guide](USER_GUIDE.md) and [Known limitations](KNOWN-LIMITATIONS.md).
3. Refresh the display list after connecting or disconnecting hardware.
4. Confirm that the problem still occurs in the latest published version.

## Ask a question or report a bug

Use [GitHub Issues](https://github.com/witqq/mac-utils/issues) as the public support channel. [mac-utils.witqq.dev](https://mac-utils.witqq.dev) is the canonical product and support website.

Use the repository issue forms and include:

- Mac Utils version and build number;
- macOS version and Mac model;
- the number and models of connected displays;
- the starting display roles and the expected/observed result;
- exact reproduction steps;
- the localized error text, if any.

Do not publish configuration files, signing credentials, tokens, private paths, or a full system profile. Display UUIDs are usually not secret, but redact them unless they are necessary to reproduce an identifier-resolution defect.

## Display diagnostics

Open **Settings… → General → Open display diagnostics** to show the app's log directory in Finder.

Display transitions automatically record correlated before/after modes, rotation, bounds, mirror membership, selected operations and native results locally. In Finder choose **Go → Go to Folder…** and enter `~/Library/Logs/com.witqq.mac-utils/` for the Direct build. For the App Store build use `~/Library/Containers/com.witqq.mac-utils/Data/Library/Logs/com.witqq.mac-utils/`. Inspect `displays.jsonl` and, if needed, `displays.previous.jsonl`; rotation retains one previous log around a 2,000,000-byte threshold. Review and redact names, identifiers and paths before attaching relevant records to a report. Mac Utils does not upload them automatically.

For a development checkout, use the existing built executable without installing another app copy:

```sh
/absolute/path/to/MacUtilsApp --display-probe
/absolute/path/to/MacUtilsApp --display-watch
```

Replace `/absolute/path/to/MacUtilsApp` with the full path to your build's executable (for an app bundle, its `Contents/MacOS/Mac Utils` executable, quoted because of the space). `--display-probe` prints a snapshot and the exact log location, then exits. `--display-watch` records the initial state and subsequent macOS screen-change events until you stop it with Control-C. Neither command reconfigures displays; reads may update independent display history.

Only when ready for brief desktop interruptions, invoke the same executable with `--display-roundtrip`. It requires exactly two active independent displays, exercises both mirror directions through the shared controller, attempts to recover the original roles, and compares final modes, rotation and geometry. With other configurations it refuses to change displays. A failure can require manual recovery in **System Settings → Displays**; native readback cannot certify the rendered pixels, so also inspect the portrait display visually. Do not infer hardware success from unit tests.

## Storage problems

Record the selected size metric, snapshot date, cache/coverage warning, action and **Details** message. Explain whether the folder moved, access changed, or a fresh scan differs from the cache. Use **Refresh** for changed metadata and select the folder again for expired access. **Manage** explains the effects of each button: confirmed **Remove Saved Scan Results…** removes snapshots but keeps folder access; confirmed **Reset Saved Locations…** also forgets saved bookmarks and requires reselection. These operations change app metadata, not files or macOS privacy permissions.

Specify **Choose Disk** versus **Choose Folder…**, analyzed root versus focused tree branch, and the progress phase, elapsed time, object count and rate if scanning stalls. Supported APFS roots read the public catalog; folders use traversal. A catalog percentage is approximate and validation follows it. A changed-during-scan note can mean a confirmed file replacement retained its first historical size once and omitted the newer version; the branch is incomplete and cleanup rejects that changed identity. Use explicit Refresh for current metadata, preferably after the activity replacing those files stops. Catalog coverage remains unverified even with no reported skips; report the warning rather than treating zero errors as proof that all private data was counted. **Disk Access…** explains optional Full Disk Access, shows the app path and opens the manual macOS privacy route. After changing permissions, follow any macOS restart request and repeat analysis; Store still needs a selected-folder grant.

Inspect `storage.jsonl` and `storage.previous.jsonl` in the same Direct/Store log directory described above. They correlate scan start, phases, two-second heartbeat, last path/count/rate, cache disposition and cancellation/failure. Trash events include moved/failure counts, changed paths, revised UUID and index/save warnings. Each file is bounded to 2,000,000 bytes. Share only relevant redacted records; paths and error text can expose private file names. No logs are uploaded automatically.

Refresh scans the selected saved disk/folder root. Tree expansion, Show More, sibling sorting and map focus read the saved index without scanning the source. Include the branch path, size metric, Largest First/Smallest First order and page when reporting a missing row. Older compact overviews require one explicit Refresh to build the tree; schema-1 full trees remain readable. The map's gray Remaining items tile summarizes children outside its current tile/page limit; those children remain reachable in the tree. Packages are browsable, but only the whole package may be moved to Trash. Mount/cloud exclusions and intentional own-cache exclusion appear as analysis notes. Tooltips and Manage/Disk Access explain effects in the interface.

The latest completed full tree is saved even when catalog coverage remains unverified; an earlier complete result is retained separately. The JSON summary is bounded to twelve roots/32 MiB, while private SQLite generations use a soft 8 GiB budget and a 512 MiB free-space reserve during building. Active readers can postpone generation removal. Revisions clone only the private cached index; native cloning must be supported on its filesystem. An older format-1 cache may build metadata indices on its first revision, without scanning source files. If an index is missing or invalid, use explicit Refresh; do not send the private database or bookmark archive to a public issue.

Successful Trash updates the current persistent tree without a source scan, retaining expanded branches, loaded pages and surviving selections. Known totals change, but the original scan date remains; unrelated changes still require Refresh. After partial success, failed items stay available. If the private index update fails, keep the historical browser and follow its Refresh warning before more Trash. If only the manifest save fails, the updated session tree remains usable but may not reopen after restart. A reopened older result remains read-only until explicit Refresh and may still list objects already moved. Durable generation protection blocks further native Trash from that historical result; it does not remove rows from its saved display. If protection cannot be recorded before moving, cleanup is refused and no items move. Report which stage failed and whether transferred items are in Finder's Trash; successful native moves were not undone. Finder's Trash remains the recovery surface. Storage deep-link navigation has a readable **System Settings → General → Storage** fallback.

Do not attach whole scan archives, bookmarks or unredacted screenshots of private file paths to public issues. A small disposable folder reproducing the problem is preferable to sharing personal metadata. Signed Store folder access remains unverified locally. Both mirror directions on the Odyssey G61SD main display with portrait G27Q on its right restored the observed native configuration, and the user confirmed uncropped rendering and correct placement. Other hardware/configurations require their own check, as described in [Known limitations](KNOWN-LIMITATIONS.md).

## Security reports

Do not open a public issue for a vulnerability or suspected credential exposure. Follow the private reporting process in [SECURITY.md](../SECURITY.md).

## Scope

Support covers the [latest published GitHub release](https://github.com/witqq/mac-utils/releases/latest) for macOS 26+. For source checkouts or local candidates, include the commit or build number; utilities documented in the current source may not yet be available in the published release. Requests for new utilities are welcome as feature proposals, but a proposal is not a release commitment.
