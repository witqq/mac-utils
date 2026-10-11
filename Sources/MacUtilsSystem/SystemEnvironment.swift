import Darwin
import Foundation
import MacUtilsCore

/// macOS-facing adapters live in this module so the core remains testable.
public enum SystemEnvironment {
    public static var productName: String { MacUtilsCore.productName }

    /// The account's home, independent of Foundation's sandbox-container directory redirection.
    public static var userHomeDirectoryURL: URL? {
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        var size = suggested > 0 ? min(Int(suggested), 1_048_576) : 4_096
        while size <= 1_048_576 {
            var buffer = [CChar](repeating: 0, count: size)
            let lookup = buffer.withUnsafeMutableBufferPointer { storage -> (CInt, String?) in
                var entry = passwd()
                var result: UnsafeMutablePointer<passwd>?
                let status = getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result)
                guard status == 0, result != nil, let directory = entry.pw_dir else { return (status, nil) }
                return (status, String(cString: directory))
            }
            if lookup.0 == ERANGE { size *= 2; continue }
            guard lookup.0 == 0, let path = lookup.1, path.hasPrefix("/"), !path.isEmpty else { return nil }
            // Keep the account entry's path as well as its target available to safety callers.
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return nil
    }
}
