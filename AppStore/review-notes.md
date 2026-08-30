# App Review notes

Mac Utils is a menu bar app and intentionally has no Dock icon. No account, network connection, or special credentials are required.

To review the main feature:

- Connect two displays before launching the app.
- Select the overlapping-display icon in the macOS menu bar, then select **Settings…**.
- In **Scripts**, create a visual script or use the onboarding recipe for **Toggle by State → Display Mode**.
- Assign the script in **Shortcuts**. The shortcut uses the native macOS global hotkey API and runs while another app is active.
- In **General**, turn **Launch Mac Utils at login** on or off. The app uses `SMAppService.mainApp`; if macOS requires approval, use **Open Login Items…**, approve the item, return to the app, and select **Refresh Status**.

Changing display mode briefly reconfigures the active desktop through public Core Graphics display configuration APIs. The App Store build is sandboxed. Configuration is stored only in the app container, and the app collects no data.

The launch-at-login control does not install a helper or LaunchAgent and is never enabled silently. Turning it off does not terminate the currently running review session.
