# Known limitations

[Русская версия](KNOWN_LIMITATIONS.ru.md)

- Mac Utils requires macOS 26 or later. Older macOS releases are not supported.
- A display that is currently an inactive mirror may expose only its hardware fallback name until it is extended again. Mac Utils still identifies it by its stable CoreGraphics UUID.
- macOS or another application may reserve a global key combination. Mac Utils reports that registration failure and keeps an existing assignment unchanged when an edit cannot be applied.
- macOS may require the user to approve automatic launch in System Settings. Mac Utils cannot bypass that system decision.
- A one-key Magic Trackpad handoff between two Macs requires peer coordination and hardware validation; it is not part of the current product. See the [feasibility report](MAGIC_TRACKPAD_FEASIBILITY.md).
- Signed release work requires the Apple Developer identities and `mac-utils-notary` Keychain profile described in [Signing and notarization](SIGNING.md). These credentials are local or cloud-managed and are intentionally not stored in the repository.
