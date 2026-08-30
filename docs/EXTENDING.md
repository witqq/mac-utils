# Extending Mac Utils

[Русская версия](EXTENDING.ru.md)

Extend existing registries and builders before creating a bespoke UI or execution route. A feature that can be expressed as an action, a state provider, or a composition of both should use those primitives.

## Add an action

Implement `UtilityAction` with a stable lowercase identifier, user-facing metadata, typed parameters, and one asynchronous operation:

```swift
enum ExampleError: Error {
    case missingValue
}

struct ExampleAction: UtilityAction {
    let metadata = ActionMetadata(
        id: ActionID("example.perform"),
        name: "Perform example",
        description: "Performs the example operation.",
        parameters: [
            ActionParameter(
                name: "value",
                type: .string,
                description: "Value used by the example operation"
            ),
        ]
    )

    func execute(
        parameters: ActionParameters,
        context: ActionContext
    ) async throws -> ActionResult {
        guard case let .string(value) = parameters["value"] else {
            throw ExampleError.missingValue
        }
        return ActionResult(summary: "Used \(value).")
    }
}
```

Register the action in the application composition root. `ActionExecutor`, the DSL, the visual builder, scripts, and hotkeys discover it through `ActionRegistry`; none of those components needs a feature-specific branch.

Keep operating-system calls behind a protocol in `MacUtilsSystem`. The action should depend on that protocol, not instantiate a concrete driver.

## Add a state provider

Implement `StateProvider` when a toggle needs to inspect live state. Metadata declares typed input, result type, and optional finite choices:

```swift
struct ExampleStateProvider: StateProvider {
    let metadata = StateProviderMetadata(
        id: StateProviderID("example.state"),
        name: "Example State",
        description: "Reads the current example state.",
        resultType: .string,
        options: [
            StateOption(value: .string("ready"), label: "Ready"),
            StateOption(value: .string("busy"), label: "Busy"),
        ]
    )

    func read(
        parameters: ActionParameters,
        context: ActionContext
    ) async throws -> ActionValue {
        .string("ready")
    }
}
```

Register it in `StateProviderRegistry`. The generic Toggle by State builder immediately provides the comparison and nested **Then**/**Otherwise** branches.

## Metadata and localization

Core metadata contains the English fallback used by non-UI consumers and third-party additions. The built-in UI resolves optional localized presentation keys:

```text
action.<action-id>.name
action.<action-id>.description
provider.<provider-id>.name
provider.<provider-id>.description
metadata.<owner-id>.parameter.<parameter-name>.label
metadata.<owner-id>.parameter.<parameter-name>.help
provider.<provider-id>.option.<serialized-value>
```

Add the same keys to English and Russian catalogs. The catalog parity test rejects missing keys or incompatible format arguments.

## Tests required for a utility

- Register and resolve the new action/provider through the shared registry.
- Validate missing, unexpected, and wrongly typed parameters.
- Execute success and failure paths against a fake system adapter.
- Prove that failure does not leave partially changed state.
- Round-trip the canonical DSL when the new metadata affects serialization.
- Cover both Toggle by State branches for a new provider.
- Add localized metadata assertions and a UI-render check when presentation changes.
- Add a safe, reversible hardware smoke only when a fake cannot establish the macOS integration contract.

Run:

```sh
./scripts/test.sh
./scripts/generate-xcode-project.sh
xcodebuild analyze -project MacUtils.xcodeproj -scheme MacUtils-Direct -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

## Extension checklist

- The identifier is stable and does not encode a localized label.
- The core contract is reusable by UI, hotkeys, and future automations.
- No SwiftUI view calls the system adapter directly.
- The DSL remains data-only and cannot execute arbitrary code.
- Errors contain structured context and receive localized presentation.
- Configuration changes remain atomic and preserve user data on failure.
- Sandbox and direct entitlements change only when the operating-system API requires it.
- Documentation describes the implemented behavior, not a planned capability.
