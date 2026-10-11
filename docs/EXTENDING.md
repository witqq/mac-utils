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

## Interactive utilities

Storage analysis uses the existing retained AppKit window and `UtilityNavigation` sidebar, with a main-actor `StorageModel` composed over `StorageManaging`. It is not a scenario action: selection, progress, cancellation, historical results and cleanup confirmation are interactive state. Reuse `StorageSnapshot`, `StorageSizeMetric`, `StorageAreaMap` and the native service contracts for the same class of work instead of adding a parallel scanner, cache or disposal route. Keep pure domain decisions in Core and filesystem/access effects in System; views render model state and route intents to it. Stateless native navigation buttons open management surfaces without analyzing or cleaning their contents.

Keep scan selection in `StorageScanner`: supported native APFS volume roots use `StorageCatalogScanner` and `StorageCatalogVolumePlan`, while ordinary folders and explicitly unsupported catalogs use directory traversal. Catalog errors or namespace changes must not silently switch to another scan. Synchronous filesystem operations use `StorageDatalessPolicy` to disable placeholder materialization and restore the worker-thread policy before suspension. Reuse the bounded `StorageDirectoryReader` and metadata cache rather than creating another file enumeration path. Keep the catalog leaf-replacement exception typed and exact: only different native leaf identities at the same verified parent/device/name may retain the first historical row once, with changedDuringScan and incomplete ancestry. Omit the incoming totals and hard-link ownership before aggregation. The private TEMP row ledger may relax only that known leaf's final check in catalog mode; retain strict root/ancestor proofs and live cleanup identity checks. Directory changes, same-identity contradictions, unknown mismatches and SQL failures remain fatal; test both the accepted historical exception and rejected cases.

Persist the scan method and preserve `StorageSnapshot.hasUnverifiedCoverage`: a catalog scan with no reported errors still cannot prove protected-area coverage. A completed schema-3 tree becomes the latest saved result while the previous complete result remains a separate backup. Legacy compact results keep the previous complete cache. Progress estimates remain approximate below completion during catalog reading and are followed by validation. Explain management and permission effects in the interface itself; macOS permissions remain the user's explicit system-setting decision. Inject `StorageDiagnostics` only into disposable test log locations; production records contain private paths.

Use the shared `StorageTreeWriter` and `StorageTreeReader` for persistent hierarchy; do not add another filesystem traversal for expansion, sibling sorting, paging or map focus. `StorageManaging.treeChildren` returns lightweight `StorageTreeRow` pages, and `treeItem` resolves a canonical actionable reference. Schema-3 IDs refer to the index rather than dense summary-array positions. Schema-1 trees remain readable; schema-2 overviews require one explicit Refresh, never an automatic folder scan. `StorageTreeView` reuses native disclosure rows with explicit Show More. Package internals are browsable but cannot be trashed separately.

Keep snapshot-to-reader binding and native generation/directory leases intact. Known successful Trash subtrees go through `StorageTreeReader.prunedSnapshot`, never a new scanner. Format-2 tombstones preserve IDs and physical nodeCount; promote a surviving duplicate if its counted hard-link path disappears. Bind the revised UUID/grant/root/auth/date/method to the original. Adopt `StorageTrashResult.updatedSnapshot` without clearing browser context, persist the primary revision and invalidate affected backups/other grants. Refuse superseded-generation mutations across restarts through durable private markers, not only an in-memory map. Record source and potentially affected saved/active UUIDs before native moves; refuse moves if protection cannot be persisted. Roll back only newly created provisional markers on no success or unaffected generations, preserving prior markers. Query `StorageManaging.isSnapshotSuperseded` on cached load and keep historical results read-only until explicit Refresh. Retain last successfully persisted latest/backup UUIDs separately from the session archive in every cleanup path; update that set only after successful load/write. Test readable byte-identical old JSON after save failure, reader release and restart. Its historical list may still include moved objects; require further native Trash to be blocked, with no second move or new revision that reintroduces old rows. Also test unsafe marker refusal. Post-native prune failure preserves a historical browser with further Trash disabled; JSON-write failure preserves the accurate active revision with a warning. Successful moves are not rolled back by either failure. Cover partial success, stable IDs/focus/pages, cross-grant lineage and these failure paths. Release obsolete, replaced and closed-window snapshots through `releaseTree(snapshotID:)`; active indices survive metadata clearing until released. Exclude the entire own tree-cache directory from scanning, and protect it and its ancestors from Trash. Verify paging and reopen with a scanner that rejects unexpected calls, canonical membership before disposal, cache-write failure cleanup, cancellation/handoff races and whole-generation eviction. Capture actual bilingual UI states at supported sizes. Tests must not mutate user files, metadata or production diagnostic logs.

## Tests required for an action or provider

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
- Stateful operating-system work goes through the model/service contract; stateless native navigation can open a management surface directly.
- The DSL remains data-only and cannot execute arbitrary code.
- Errors contain structured context and receive localized presentation.
- Configuration changes remain atomic and preserve user data on failure.
- Sandbox and direct entitlements change only when the operating-system API requires it.
- Documentation describes the implemented behavior, not a planned capability.
