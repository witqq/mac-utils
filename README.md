# Mac Utils

[Русская версия](README.ru.md)

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111?logo=apple)](docs/KNOWN-LIMITATIONS.md)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/witqq/mac-utils/actions/workflows/ci.yml/badge.svg)](https://github.com/witqq/mac-utils/actions/workflows/ci.yml)

Mac Utils is a native menu bar application for building dependable macOS utility shortcuts without writing code. The first utility controls connected displays: make a display main, extend the desktop, mirror another display, or switch between layouts according to the current state.

## Availability

Mac Utils requires macOS 26 or later.

- **Source and issues:** [github.com/witqq/mac-utils](https://github.com/witqq/mac-utils) is the public project repository.
- **GitHub Releases:** the notarized DMG will be published with v1.0.0 on the repository’s [Releases page](https://github.com/witqq/mac-utils/releases). The first public release is not available yet.
- **Mac App Store:** the product link will be added after Apple publishes v1.0.0.
- **Website and support:** `https://mac-utils.witqq.dev` is the canonical address being prepared for the first release.

The release download, App Store product, and website remain marked as pending until their publication steps complete. Development builds are available from this repository.

## What it does

- Lives in the macOS menu bar without a Dock icon.
- Reads connected displays and shows their main, extended, or mirrored role.
- Builds multi-step scripts with a visual editor and typed controls.
- Uses **Toggle by State** to choose a branch from the live display state.
- Assigns one native global keyboard shortcut to an entire script.
- Safely edits shortcuts: a conflicting or unavailable replacement leaves the previous shortcut active.
- Stores configuration locally and supports English, Russian, or the system language.

Mac Utils scripts can call only actions registered by the application. They cannot execute shell commands or arbitrary downloaded code.

## Quick start

### Run a development build

Install Xcode 26 with its command-line tools, then run:

```sh
./scripts/test.sh
./scripts/run.sh
```

The overlapping-displays icon appears in the menu bar. Open it, select **Settings…**, and follow the onboarding screen.

### Build a mirror/extend toggle without code

1. Open **Settings… → Scripts** and select **+**.
2. Enter a name such as `Toggle office displays`.
3. Select **Add Step → Toggle by State → Display Mode**.
4. Choose the secondary display and set **When state is** to **Mirror**.
5. Under **Then**, add **Extend display** for the secondary display.
6. Under **Otherwise**, add **Mirror display**; choose the secondary display and the main display as **Source**.
7. Select **Save**, open **Shortcuts**, record a combination, and select **Assign**.

The same key now extends a mirrored display and mirrors it again when it is extended. The built-in **Help** tab explains the terms and workflow.

## Documentation

- [User guide](docs/USER_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Adding utilities, actions, and state providers](docs/EXTENDING.md)
- [Privacy](docs/PRIVACY.md)
- [Support](docs/SUPPORT.md)
- [Security policy](SECURITY.md)
- [Known limitations](docs/KNOWN-LIMITATIONS.md)
- [Contributing](CONTRIBUTING.md)
- [Release operations](docs/RELEASING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)
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
- `MacUtilsSystem` implements CoreGraphics display control, native Carbon hotkeys, and atomic configuration storage.
- `MacUtilsApp` composes the registries and presents the menu bar and settings UI.

See [Architecture](docs/ARCHITECTURE.md) before changing module boundaries.

## Privacy and security

Mac Utils has no analytics, advertising, account system, or network client. Scripts and shortcut assignments are stored in the app’s local Application Support container. See [Privacy](docs/PRIVACY.md) and report vulnerabilities through the private process in [SECURITY.md](SECURITY.md).

## License

Mac Utils is available under the [MIT License](LICENSE).
