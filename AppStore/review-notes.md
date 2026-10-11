# App Review notes

Mac Utils is a menu bar app and intentionally has no Dock icon. It builds scripts from registered actions and runs each script with one global keyboard shortcut. No account, network connection, or special credentials are required.

To review scripts and display actions:

- Connect two displays before launching the app.
- Select the overlapping-display icon in the macOS menu bar, then select **Settings…**.
- In **Scripts**, create a visual script or use the onboarding recipe for **Toggle by State → Display Mode**.
- Assign the script in **Shortcuts**. The shortcut uses the native macOS global hotkey API and runs while another app is active.
- In **General**, turn **Launch Mac Utils at login** on or off. The app uses `SMAppService.mainApp`; if macOS requires approval, use **Open Login Items…**, approve the item, return to the app, and select **Refresh Status**.

Changing display mode briefly reconfigures the active desktop through public Core Graphics display configuration APIs. The App Store build is sandboxed. Configuration is stored only in the app container, and the app collects no data.

The launch-at-login control does not install a helper or LaunchAgent and is never enabled silently. Turning it off does not terminate the currently running review session.

To review storage analysis safely:

- Open **Storage** in the utility window's sidebar. Choose **Choose Folder…** and grant access to a small disposable review folder containing sample files and subfolders. Store access uses user-selected read/write access and app-scoped security bookmarks; protected paths can remain unavailable.
- Wait for analysis, expand a subfolder, change **Logical size** / **Allocated**, and change the sibling sort order. Paging and navigation use the saved tree without rescanning. **Refresh** explicitly starts a new analysis of the selected root. The optional **Size Map** and **Largest files** views show the analyzed metadata.
- Select a disposable subfolder and choose **Move to Trash**. Review its full path in the confirmation sheet: the entire folder and its contents move to Finder's Trash. Surviving tree branches and browsing state remain available. Restore the folder in Finder if desired; the app does not permanently delete files or empty Trash.
- **Manage** explains removal of saved locations and analysis results. These controls change app metadata, not the selected folder's contents. **Disk Access…** explains macOS permissions; it does not grant them. Full Disk Access does not replace the Store build's native selection grant.

Analysis reads filesystem metadata, not file contents. APFS catalog coverage can be unverified even with no reported skips, and allocated sizes do not measure exclusive or reclaimable storage. Approximate catalog progress is identified as such. If revising saved metadata after a Trash move fails, the app reports the failure and protects historical results from further Trash until an explicit refresh. No automatic cleanup runs.

The window supports resizing and native full-screen mode. It retains a minimum 960×720-point content area. Display preferences are stored by stable display UUID; their remembered relative positions can be left, right or vertically offset. The app observes rotation but does not change it. Prepare the independent arrangement in macOS Displays settings before reviewing mirror/extend restoration.
