# Magic Trackpad sharing feasibility

[Русская версия](MAGIC_TRACKPAD_FEASIBILITY.ru.md)

## User goal

The target workflow is one Magic Trackpad used with two nearby Macs without manually pairing or reconnecting it for every switch.

## Finding

Keep the Magic Trackpad connected to one Mac and use Apple's Universal Control to operate the second Mac. This is the supported arrangement: the trackpad remains owned by its host Mac, while macOS carries pointer and keyboard input between nearby Macs.

Mac Utils does not pair, disconnect, or transfer the trackpad. Apple's public Bluetooth APIs do not provide a reliable cross-Mac ownership transfer for a HID device. Testing showed that a Bluetooth connection request can appear briefly on the receiving Mac and still fall back to the original Mac without delivering usable input.

The Direct build instead provides **Refresh Universal Control**. It locally restarts the fixed set of Continuity processes involved in the connection and lets macOS establish Universal Control again. The action uses the common script engine, so it can be placed in a visual script and assigned to a global shortcut. It performs no network peer discovery and stores no peer or trackpad credentials.

## Distribution and privacy constraints

- **Refresh Universal Control** is Direct-only because it terminates system-owned processes and relies on launchd to restart them. The Mac App Store build compiles the action out.
- Refreshing can briefly interrupt Universal Control, Handoff, AirDrop, Sidecar, or Universal Clipboard activity on that Mac.
- The action is recovery assistance, not an Apple connection API. It cannot guarantee reconnection when Universal Control requirements, Apple Account state, network conditions, or macOS settings are not satisfied.
- Run the action on the Mac whose Universal Control connection needs recovery. If necessary, run it on both Macs using a separately configured local shortcut on each installation.

## Recommended next step

Use the [user guide](USER_GUIDE.md) to create a one-step refresh script and bind it to a global shortcut. Keep the trackpad paired to its normal host Mac and configure Universal Control in macOS on both computers.

## Primary sources

- [Set up a Magic Trackpad with a Mac](https://support.apple.com/en-asia/119917) documents cable-assisted pairing and normal wireless use.
- [Universal Control](https://support.apple.com/en-us/102459) documents sharing a Mac keyboard, mouse, or trackpad across nearby Macs and the supported connection controls.
