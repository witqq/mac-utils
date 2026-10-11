import AppKit
import Foundation

/// Opens native management surfaces without reading or deleting their contents.
@MainActor
public enum StorageNativeTools {
    public static var applicationURL: URL {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle
            : URL(fileURLWithPath: "/Applications/Mac Utils.app", isDirectory: true)
    }

    /// A best-effort Settings deep link; the UI also supplies the full manual route.
    public static func openFullDiskAccessSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return false }
        return NSWorkspace.shared.open(url)
    }
    public static func openStorageSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") else { return false }
        return NSWorkspace.shared.open(url)
    }
    public static func openDownloads() -> Bool {
        guard let home = SystemEnvironment.userHomeDirectoryURL else { return false }
        return NSWorkspace.shared.open(home.appending(path: "Downloads"))
    }
    public static func openTrash() -> Bool {
        guard let home = SystemEnvironment.userHomeDirectoryURL else { return false }
        return NSWorkspace.shared.open(home.appending(path: ".Trash"))
    }
    public static func openDisplayLogs() -> Bool {
        NSWorkspace.shared.open(DisplayDiagnostics.defaultDirectoryURL)
    }
}
