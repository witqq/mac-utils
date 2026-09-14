# Mac Utils

[Русская версия](README.ru.md)

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111?logo=apple)](docs/KNOWN-LIMITATIONS.md)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/witqq/mac-utils/actions/workflows/ci.yml/badge.svg)](https://github.com/witqq/mac-utils/actions/workflows/ci.yml)

Mac Utils is a native macOS menu bar app for building scripts out of ready-made actions and running each script with one global keyboard shortcut from any application. Compose the steps visually, branch on the live system state, assign a key, and press it wherever you are. The catalog of actions keeps growing: today it covers display roles and layouts, launch at login, and, in the Direct build, closing every notification and refreshing Universal Control.

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
- **Menu bar only.** Mac Utils lives in the menu bar without a Dock icon, stores its configuration locally, and speaks English, Russian, or the system language.

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

- `MacUtilsCore` defines actions, typed parameters, scenarios, state providers, and the safe DSL.
- `MacUtilsSystem` implements the system-facing actions (CoreGraphics display control, Accessibility-based notification dismissal, Continuity service refresh), native Carbon hotkeys, the Service Management login-item adapter, and atomic configuration storage.
- `MacUtilsApp` composes the registries and presents the menu bar and settings UI.

See [Architecture](docs/ARCHITECTURE.md) before changing module boundaries.

## Privacy and security

Mac Utils has no analytics, advertising, account system, or network client. Scripts and shortcut assignments are stored in the app’s local Application Support container. See [Privacy](docs/PRIVACY.md) and report vulnerabilities through the private process in [SECURITY.md](SECURITY.md).

## License

Mac Utils is available under the [MIT License](LICENSE).
