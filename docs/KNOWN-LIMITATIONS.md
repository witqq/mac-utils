# Known limitations

[Русская версия](KNOWN_LIMITATIONS.ru.md)

- Mac Utils requires macOS 26 or later. Older macOS releases are not supported.
- A display that is currently an inactive mirror may expose only its hardware fallback name until it is extended again. Mac Utils still identifies it by its stable CoreGraphics UUID.
- When a display leaves mirroring, Mac Utils selects the mode the panel reports as default (or native) from the CoreGraphics mode catalog. A panel that reports neither flag keeps the mode macOS chose for the mirror pair. Restoring a rotated display's own mode after un-mirroring has been verified by logic and unit tests, not yet on rotated hardware.
- Mac Utils does not save or restore the positions of other applications' windows. macOS may rearrange windows whenever display roles or layout change.
- macOS or another application may reserve a global key combination. Mac Utils reports that registration failure and keeps an existing assignment unchanged when an edit cannot be applied.
- macOS may require the user to approve automatic launch in System Settings. Mac Utils cannot bypass that system decision.
- **Refresh Universal Control** is available only in Direct builds and is compiled out of the Mac App Store build. It restarts local Continuity processes, can briefly interrupt related Apple services, and cannot guarantee reconnection when the underlying Universal Control requirements are not met. It does not pair or transfer a Magic Trackpad. See the [feasibility report](MAGIC_TRACKPAD_FEASIBILITY.md).
- **Dismiss all notifications** is available only in Direct builds and is compiled out of the Mac App Store build. It requires Accessibility access, relies on the Notification Center's accessibility structure and the localized names of its Close and Clear All actions (read from the system bundle), and may need an update after a macOS release that changes that structure. A script run from a global shortcut does not display its failure message in the app; a missing permission is visible only through the macOS prompt.
- Signed release work requires the Apple Developer identities and `mac-utils-notary` Keychain profile described in [Signing and notarization](SIGNING.md). These credentials are local or cloud-managed and are intentionally not stored in the repository.
