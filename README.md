# Mac Utils

[Русская версия](README.ru.md)

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111?logo=apple)](docs/KNOWN-LIMITATIONS.md)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/witqq/mac-utils/actions/workflows/ci.yml/badge.svg)](https://github.com/witqq/mac-utils/actions/workflows/ci.yml)

Mac Utils is a native macOS menu bar app with storage analysis and reusable automation scripts. Analyze a folder or disk in a resizable, fullscreen-capable window with a proportional size map, dated scan cache and selected-item cleanup through Trash. Compose automation steps visually, branch on live system state and run a script with one global shortcut. Actions cover display roles and layouts and, in the Direct build, closing notifications and refreshing Universal Control; launch at login is a setting.

## Availability

Mac Utils requires macOS 26 or later.

- **Source and issues:** [github.com/witqq/mac-utils](https://github.com/witqq/mac-utils) is the public project repository.
- **GitHub Releases:** download the notarized DMG and its SHA-256 checksum from the [latest release](https://github.com/witqq/mac-utils/releases/latest). The Direct build from GitHub contains every action, including the ones that the Mac App Store sandbox cannot run.
- **Mac App Store:** the sandboxed Store build is in review; the product link will be added after Apple publishes it.
- **Website and support:** [mac-utils.witqq.dev](https://mac-utils.witqq.dev) is the canonical marketing and support address.

The Mac App Store product remains marked as pending until Apple publication completes. Development builds are available from this repository.

## How it works

- **Scripts.** A script is an ordered list of actions built in a visual editor with typed controls, or written in a small data-only DSL.
- **Toggle by State.** A script can read a live state and run one branch when it matches and another when it does not, so one key toggles instead of guessing what happened last time.
- **Global shortcuts.** One native macOS shortcut runs the whole script while any application is active. A conflicting or unavailable replacement leaves the previous shortcut working.
- **Storage.** Browse folders and largest files, choose logical or allocated sizes, refresh cached snapshots, and review selected items before moving them to Trash. Native macOS Storage, Downloads and Trash buttons open management surfaces.
- **Menu bar and utility window.** Mac Utils has no Dock icon. Its menu bar opens a shared window with sidebar navigation for Storage, Scripts, Shortcuts, General and Help. Data stays local; the interface supports English, Russian or the system language.

Scripts can call only actions registered by the application. They cannot execute shell commands or arbitrary downloaded code.

## Actions available today

| Action | What it does | Builds |
| --- | --- | --- |
| Set main display | Makes a connected display the macOS main display. | Direct, App Store |
| Extend display | Takes a display out of mirroring and adds it as desktop space. | Direct, App Store |
| Mirror display | Makes one display mirror another. | Direct, App Store |
| Display Mode (state) | Reads whether a display is main, extended, or mirrored for Toggle by State. | Direct, App Store |
| Dismiss all notifications | Closes every Notification Center banner, alert, and stack through Accessibility. | Direct |
| Refresh Universal Control | Restarts the local Continuity services so Universal Control reconnects. | Direct |

Launch at login is a setting rather than an action: it uses the macOS Login Items service and shows the live approval status. Direct-only actions need capabilities that the App Store sandbox does not allow; see [Known limitations](docs/KNOWN-LIMITATIONS.md). New actions plug into the same registries; [Adding utilities, actions, and state providers](docs/EXTENDING.md) explains how.

## Quick start

### Run a development build

Install Xcode 26 with its command-line tools, then run:

```sh
./scripts/test.sh
./scripts/run.sh
```

The overlapping-displays icon appears in the menu bar. Open it, select **Settings…**, and follow the onboarding screen.

### Build your first script without code

1. Open **Settings… → Scripts** and select **+**.
2. Enter a name such as `Clear the screen`.
3. Select **Add Step** and pick an action, for example **Dismiss all notifications** (Direct build) or a display action.
4. Add more steps or a **Toggle by State** block when the script should react to the current state.
5. Select **Save**, open **Shortcuts**, record a combination, and select **Assign**.

The key now runs the whole script from any application. The built-in **Help** tab explains the terms and includes a ready mirror/extend toggle recipe; the [User guide](docs/USER_GUIDE.md) walks through every action.

### Analyze storage

Choose **Analyze Storage…** in the menu bar, then **Choose Disk** for a named mounted volume, including the startup disk, or **Choose Folder…** for a smaller area. Supported APFS volume roots use the public macOS filesystem catalog; folders and unsupported volumes use directory traversal with batched metadata where available. Progress shows the phase, elapsed time, processed objects, average rate and counted sizes. A catalog percentage is explicitly approximate; validation follows it.

The saved tree retains analyzed folders and files at every depth. Expand branches, load more children and sort by logical or allocated size without scanning again. Packages can be browsed; cleanup selects the whole package. The optional **Size Map** follows the focused folder. Catalog results warn that protected-area coverage is unverified, even with no reported skips; the latest tree is saved separately from an earlier complete backup. **Refresh** rescans the selected location; **Move to Trash** requires confirmation and rechecks selected items. Successful moves update the saved tree and known sizes while preserving browsing, without another source scan. **Manage** explains saved-data actions beside their buttons. **Disk Access…** shows how you can enable Full Disk Access in macOS; the app cannot grant it itself. Cached results are historical, allocated sums are not exclusive APFS usage, and moving to Trash does not immediately free space. See the [User guide](docs/USER_GUIDE.md) for navigation, access and cleanup boundaries.

## Documentation

- [User guide](docs/USER_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Adding utilities, actions, and state providers](docs/EXTENDING.md)
- [Privacy](docs/PRIVACY.md)
- [Support](docs/SUPPORT.md)
- [Security policy](SECURITY.md)
- [Known limitations](docs/KNOWN-LIMITATIONS.md)
- [Magic Trackpad switching feasibility](docs/MAGIC_TRACKPAD_FEASIBILITY.md)
- [Contributing](CONTRIBUTING.md)
- [Release operations](docs/RELEASING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)
- [v1.2.1 release notes](docs/releases/v1.2.1.md)
- [v1.2.0 release notes](docs/releases/v1.2.0.md)
- [v1.1.0 release notes](docs/releases/v1.1.0.md)
- [v1.0.0 release notes](docs/releases/v1.0.0.md)

## Development

The Swift Package Manager project is the module source of truth. `project.yml` is the source of truth for the generated Xcode project.

```sh
./scripts/build-debug.sh
./scripts/test.sh
./scripts/check-docs.sh
./scripts/generate-xcode-project.sh
./scripts/archive-xcode-local.sh direct
./scripts/archive-xcode-local.sh app-store
```

XcodeGen 2.46.0 or later is required for project generation. Local archive commands use identities from the developer’s Keychain; public release signing and notarization use protected GitHub environments.

Core modules:

- `MacUtilsCore` defines actions, typed parameters, scenarios, state providers, the safe DSL, immutable storage snapshots and pure proportional map layout.
- `MacUtilsSystem` implements system-facing actions, native hotkeys and login items, display history/diagnostics, metadata scanning, a shared persistent SQLite tree, folder access, bounded scan caches and native Trash/reveal.
- `MacUtilsApp` composes the registries and interactive storage model, and presents the menu bar and shared utility window.

See [Architecture](docs/ARCHITECTURE.md) before changing module boundaries.

## Privacy and security

Mac Utils has no analytics, advertising, account system, or network client. Scripts, shortcuts, display history and selected-folder bookmarks stay in local Application Support; storage metadata snapshots stay in local Caches, and display/storage diagnostics in local Logs. Metadata operations disable cloud-placeholder materialization on their worker thread and restore its prior policy afterward; scans do not open file contents. Full Disk Access is an optional broad permission enabled by you in macOS settings. See [Privacy](docs/PRIVACY.md) and report vulnerabilities through the private process in [SECURITY.md](SECURITY.md).

## License

Mac Utils is available under the [MIT License](LICENSE).
