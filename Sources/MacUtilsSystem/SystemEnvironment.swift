import MacUtilsCore

/// macOS-facing adapters live in this module so the core remains testable.
public enum SystemEnvironment {
    public static var productName: String { MacUtilsCore.productName }
}
