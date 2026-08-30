# Privacy

[Русская версия](PRIVACY.ru.md)

Mac Utils is designed to work entirely on the Mac where it is installed.

## Data collection

Mac Utils does not collect, transmit, sell, or share personal data. The application contains no analytics SDK, advertising SDK, account system, telemetry client, or network client.

There is no developer-operated backend for the application.

## Data stored on the Mac

Mac Utils stores only the configuration needed to perform user-created automations:

- script identifiers, names, and safe DSL source;
- global keyboard shortcut key codes and modifiers;
- stable CoreGraphics display UUIDs selected in script parameters;
- the selected application language in macOS user defaults.

The JSON configuration is stored in the user’s Application Support directory. In the Mac App Store build, macOS places it inside the application sandbox container. Writes use atomic replacement.

Mac Utils reads the current connected-display list and layout from macOS when displaying the UI or executing a display action. That information remains on the Mac.

## Permissions

The Mac App Store build uses App Sandbox. Native global hotkeys and CoreGraphics display configuration were verified in a sandboxed local build without an Accessibility permission request.

Mac Utils does not request Contacts, Calendars, Photos, Camera, Microphone, Location, Screen Recording, Full Disk Access, or Automation access for its product features.

## Diagnostics

Explicit developer smoke commands can print display names, stable display UUIDs, configuration counts, and status values to the invoking terminal. They run only when a developer starts the executable with a diagnostic command-line flag. Mac Utils does not upload this output.

## Removing local data

Delete scripts and shortcuts in the application before uninstalling. To remove all remaining configuration, delete the Mac Utils Application Support data or the sandbox container through macOS after quitting the application.

The exact public support instructions and App Store privacy declaration will remain aligned with this behavior. If a future version adds any network or data-processing feature, this document and the App Store disclosure must be updated before release.

Privacy questions can be submitted through the process in [Support](SUPPORT.md).
