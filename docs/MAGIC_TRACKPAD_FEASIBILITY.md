# Magic Trackpad switching feasibility

[Русская версия](MAGIC_TRACKPAD_FEASIBILITY.ru.md)

## User goal

The target workflow is one Magic Trackpad shared by two Macs. Pressing a Mac Utils global shortcut on the active Mac should make the trackpad usable there and allow switching it back later.

## Finding

The exact one-key workflow is technically plausible as a future, opt-in feature, but it is not a local Bluetooth action that one Mac can perform reliably by itself. A supported design needs Mac Utils running on both Macs and a trusted peer-to-peer handoff protocol:

1. the receiving Mac asks the peer Mac to release the selected trackpad;
2. the peer closes its Bluetooth connection and confirms the result;
3. the receiving Mac opens its own connection to the already paired trackpad;
4. the UI reports partial failure instead of pretending the handoff succeeded.

Apple's public `IOBluetoothDevice` API can enumerate paired devices and request baseband connection creation or closure. That makes a controlled prototype possible without private frameworks. It does not provide a cross-Mac ownership transaction: a local process cannot force a different Mac to release the HID device, so peer coordination and failure recovery are essential.

## Distribution and privacy constraints

- The Mac App Store build would need the App Sandbox Bluetooth entitlement and a Bluetooth usage explanation. An entitlement grants capability; macOS may still require explicit user permission.
- Automatic peer discovery or commands between Macs would add local-network communication to a product that currently has no network client. The feature would therefore require explicit opt-in, authenticated pairing between the two Mac Utils installations, updated privacy disclosures, and a review of the App Store networking entitlements.
- The trackpad must already be paired with both Macs. Apple documents cable-assisted pairing and manual connect/disconnect behavior; Mac Utils must not silently forget or re-pair the device.
- A hotkey must never leave both sides believing they own the trackpad. The protocol needs timeouts, acknowledgement, idempotent retry, and a visible manual recovery path.

## Recommended next step

Do not add Bluetooth code to the current release. First distribute a separate Developer ID-signed and notarized Direct DMG to both physical Macs and test it with one Magic Trackpad. The prototype should use only public `IOBluetooth` calls, record exact `IOReturn` results, verify whether the specific trackpad remains paired with both Macs, and exercise failure cases when either Mac sleeps, is offline, or refuses the connection. Consider TestFlight and App Store work only after that hardware evidence is reproducible.

For immediate use, Apple’s supported Universal Control feature is safer: keep the trackpad connected to one Mac and move its pointer and keyboard control between nearby Macs. Universal Control can automatically reconnect nearby devices, but Apple exposes its connection controls through Control Center and Displays settings rather than an application API for a custom Mac Utils handoff hotkey.

## Primary sources

- [IOBluetoothDevice](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice) documents paired-device lookup, connection state, `openConnection()`, and `closeConnection()`.
- [Bluetooth App Sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth) documents the capability required for a sandboxed app to interact with Bluetooth devices.
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox) explains that hardware entitlements declare intent and do not replace user permission.
- [Set up a Magic Trackpad with a Mac](https://support.apple.com/en-asia/119917) documents cable-assisted pairing and normal wireless use.
- [Universal Control](https://support.apple.com/en-us/102459) documents sharing a Mac keyboard, mouse, or trackpad across nearby Macs and the supported connection controls.
