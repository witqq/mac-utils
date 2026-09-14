# Changelog

All notable public changes to Mac Utils are recorded here.

## 1.2.1 — 2026-09-14

### Fixed

- The menu bar popover opens attached under its status item instead of as a panel detached from the menu bar, and it takes keyboard focus, so Escape closes it without the mouse. Its content now reports its own size, which is what `NSPopover` uses to place itself.
- The Quit control in the menu bar popover names the application instead of showing a raw format specifier. The quit label was defined twice in each localization catalog, and the repeated definition won.

See [v1.2.1 release notes](docs/releases/v1.2.1.md).

## 1.2.0 — 2026-09-12

### Added

- **Dismiss all notifications** action in Direct builds: closes every visible Notification Center banner, alert and stacked group through Accessibility, using the Notification Center's own localized Close and Clear All actions.
- Optional launch at login through the public macOS Service Management API.
- A bilingual General settings screen with live enabled, disabled, approval-required, and unavailable states plus a direct handoff to Login Items in System Settings.

### Fixed

- A display that leaves mirroring (Extend display, Set main display, or a mirror source that is re-mirrored elsewhere) now returns to its own default display mode instead of keeping the mode macOS chose for the mirror pair, so a rotated display keeps its own orientation and resolution.

### Changed

- App Store export-compliance answers are streamlined by declaring that the app does not use non-exempt encryption.
- The documented future Magic Trackpad handoff now has a public-API feasibility report and a two-Mac prototype boundary.
- **Refresh Universal Control** action in Direct builds restarts the local Continuity services so Universal Control reconnects.
- README, App Store metadata, onboarding, and the landing describe Mac Utils as a script builder with global shortcuts whose action catalog grows; the landing is now generated with agentic-report.

See [v1.2.0 release notes](docs/releases/v1.2.0.md).

## 1.0.0 — 2026-08-30

### Added

- Native macOS 26+ menu bar application without a Dock icon.
- CoreGraphics display discovery with stable UUIDs and atomic main, extended, and mirror operations.
- Extensible typed action and state-provider registries.
- Safe multi-step scenarios and a data-only DSL with line/column diagnostics.
- Universal Toggle by State with nested visual branches.
- Native Carbon global hotkeys that execute whole scenarios.
- Transactional shortcut editing with conflict preservation and rollback handling.
- Atomic local configuration and recovery from invalid JSON/schema data.
- Visual script builder, onboarding, built-in help, tooltips, empty/loading/error states, and destructive-action confirmation.
- English and Russian UI, metadata, errors, help, and accessibility presentation with system or explicit language selection.
- Reproducible XcodeGen project with separate Direct, App Store, and UI-test schemes.
- App Sandbox compatibility verified for display control, global hotkeys, UI, and local configuration.

### Security and privacy

- Scripts resolve only registered actions/providers and cannot execute arbitrary code or shell commands.
- No analytics, ads, accounts, network client, or developer backend.
- Direct and App Store entitlements are separated; App Store uses App Sandbox.

See [v1.0.0 release notes](docs/releases/v1.0.0.md) and the [signed GitHub release](https://github.com/witqq/mac-utils/releases/tag/v1.0.0).
