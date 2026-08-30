# Mac Utils user guide

[Русская версия](USER_GUIDE.ru.md)

Mac Utils runs from the macOS menu bar. It turns a sequence of registered utility actions into a reusable script, then lets one global keyboard shortcut run that script from any application.

## Requirements and installation

Mac Utils requires macOS 26 or later.

The first public build is not published yet. When v1.0.0 is available, use one of these channels:

- download the notarized DMG from GitHub Releases at `https://github.com/witqq/mac-utils/releases`, open it, and drag **Mac Utils** to **Applications**;
- install the Mac App Store build from the product link that will be added after Apple publishes it.

Until then, developers can run `./scripts/run.sh` from a source checkout.

## First launch

Mac Utils has no Dock icon. Find the overlapping-displays icon in the menu bar.

1. Open the menu bar item.
2. Select **Settings…**.
3. Read the onboarding cards or open the **Help** tab.
4. Choose **Language → System**, **English**, or **Русский**. The choice applies only to Mac Utils unless **System** is selected.

## Display terms

- **Main display** contains the menu bar and establishes the origin of the desktop layout.
- **Extended display** adds separate desktop space.
- **Mirror** shows the content of another display.
- **Toggle by State** reads a current value. It runs **Then** when the value matches and **Otherwise** when it does not.

The menu bar popover lists each connected display, its current role, and resolution. Its **Main**, **Extend**, and **Mirror** controls execute the same registered actions used by scripts.

## Build a script visually

1. Open **Settings… → Scripts**.
2. Select **+** and enter a descriptive name.
3. Select **Add Step** and choose an action or a **Toggle by State** provider.
4. Choose displays by their macOS names. Mac Utils stores their stable CoreGraphics identifiers.
5. Reorder steps with the arrow buttons or drag and drop. A step can also be duplicated or deleted.
6. Select **Validate** to check every action, parameter, and nested branch.
7. Select **Save**.

Deleting a script requires confirmation and also removes its shortcut assignments. Deleting a draft builder step requires a separate confirmation.

## Mirror/extend toggle recipe

Create one **Toggle by State → Display Mode** step:

- **Display:** the secondary display.
- **When state is:** **Mirror**.
- **Then:** **Extend display** with the same secondary display.
- **Otherwise:** **Mirror display** with the secondary display as **Display** and the main display as **Source**.

This is a universal state-driven toggle: it reads the live display state every time instead of remembering which branch ran previously.

## Assign and edit a global shortcut

1. Open **Settings… → Shortcuts**.
2. Choose a saved script.
3. Select **Record Shortcut** and press a key with Control, Option, or Command. Escape cancels recording.
4. Select **Assign**.

One shortcut runs every step in its script in order. To change it, select **Edit**, record a replacement, and select **Save Change**. Mac Utils registers the replacement before removing the previous assignment. If macOS or another in-app binding rejects the replacement, the previous shortcut remains active.

Removing a shortcut requires confirmation but does not delete its script.

## Optional DSL editor

The visual builder is the recommended editor. **DSL Text** exposes the same safe scenario representation for advanced users. It does not evaluate expressions, access files, launch processes, or run shell code.

One action is written per line with quoted named parameters:

```text
extend-display display="SECONDARY-DISPLAY-UUID"
```

A state toggle uses explicit blocks:

```text
@toggle provider="display.mode" equals="mirror" display="SECONDARY-DISPLAY-UUID"
  @match
    extend-display display="SECONDARY-DISPLAY-UUID"
  @otherwise
    mirror-display display="SECONDARY-DISPLAY-UUID" source="MAIN-DISPLAY-UUID"
@end
```

Comments begin with `#`. Switching back to the visual builder is allowed only after the entire text parses and validates, so invalid text cannot replace the last valid visual model.

## Local data and recovery

Configuration is stored as JSON under the application’s Application Support directory. The App Store build receives the normal sandbox container path automatically. Writes are atomic.

Do not edit the file while Mac Utils is running. If JSON or schema validation fails, Mac Utils starts with a safe empty configuration and shows the error. A saved script or shortcut that cannot currently activate remains visible so it can be corrected or removed without silent data loss.

## Troubleshooting

- **A display is missing:** reconnect it, then select the refresh button in the menu bar popover.
- **A mirrored display has a generic name:** extend it once so macOS exposes its localized name again. Its stable identifier remains unchanged.
- **A shortcut is unavailable:** record a different combination. The existing shortcut remains active during a failed edit.
- **A script does not validate:** read the localized line and column message, or switch to the visual builder after correcting the DSL.
- **The UI does not appear in the Dock:** this is expected; Mac Utils is a menu bar accessory application.

See [Known limitations](KNOWN-LIMITATIONS.md) and [Support](SUPPORT.md) for confirmed constraints and reporting instructions.
