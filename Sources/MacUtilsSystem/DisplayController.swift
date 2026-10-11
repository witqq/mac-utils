import Foundation
import MacUtilsCore

struct DisplayHistory: Codable, Sendable {
    var version = 1
    var displays: [DisplayID: DisplayDescriptor] = [:]
}

protocol DisplayHistoryStoring: Sendable {
    func load() async throws -> DisplayHistory
    func save(_ history: DisplayHistory) async throws
}

actor DisplayHistoryStore: DisplayHistoryStoring {
    private let store: AtomicJSONFileStore<DisplayHistory>
    init(fileURL: URL) { store = AtomicJSONFileStore(fileURL: fileURL) }
    static var defaultFileURL: URL {
        ConfigurationStore.defaultFileURL.deletingLastPathComponent().appending(path: "display-history.json")
    }
    func load() async throws -> DisplayHistory {
        switch await store.read() {
        case .missing: return DisplayHistory()
        case let .value(history):
            guard history.version == 1, history.displays.allSatisfy({ id, display in
                let independent: Bool
                if case .mirror = display.role { independent = false } else { independent = display.isInMirrorSet != true }
                return independent && id == display.id && !id.rawValue.isEmpty && display.frame.width > 0 && display.frame.height > 0
                    && (display.mode?.isValid ?? true) && (display.rotation?.isFinite ?? true)
            }) else { throw DisplayManagerError.systemFailure("Saved display history is invalid or unsupported") }
            return history
        case let .failure(error): throw DisplayManagerError.systemFailure("Cannot load display history: \(error)")
        }
    }
    func save(_ history: DisplayHistory) async throws { try await store.write(history) }
}

protocol DisplayConfigurationDriver: Sendable {
    func readDisplays() async throws -> [DisplayDescriptor]
    func apply(_ operations: [DisplayConfigurationOperation]) async throws
}

public actor DisplayController: DisplayManaging {
    private let driver: any DisplayConfigurationDriver
    private let historyStore: (any DisplayHistoryStoring)?
    private let diagnostics: DisplayDiagnostics?
    private var history: DisplayHistory?
    private var mutationInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(driver: any DisplayConfigurationDriver, historyStore: (any DisplayHistoryStoring)? = nil,
         diagnostics: DisplayDiagnostics? = nil) {
        self.driver = driver
        self.historyStore = historyStore
        self.diagnostics = diagnostics
    }

    public init() {
        driver = CoreGraphicsDisplayDriver()
        historyStore = DisplayHistoryStore(fileURL: DisplayHistoryStore.defaultFileURL)
        diagnostics = .shared
    }

    public func displays() async throws -> [DisplayDescriptor] {
        await acquireMutation()
        defer { releaseMutation() }
        let snapshot = try await driver.readDisplays()
        try await rememberIndependent(snapshot)
        return snapshot
    }

    public func setMainDisplay(_ display: DisplayID) async throws {
        try await mutate { snapshot in
            if snapshot.first(where: { $0.id == display })?.role == .main { return [] }
            return try DisplayLayoutPlanner.setMain(display, displays: snapshot)
        }
    }

    public func setExtendedDisplay(_ display: DisplayID) async throws {
        try await mutate { try DisplayLayoutPlanner.setExtended(display, displays: $0) }
    }

    public func setMirrorDisplay(_ display: DisplayID, source: DisplayID) async throws {
        try await mutate { snapshot in
            let result = try DisplayLayoutPlanner.setMirror(display, source: source, displays: snapshot)
            if snapshot.first(where: { $0.id == display })?.role == .mirror(source: source) { return [] }
            return result
        }
    }

    private func acquireMutation() async {
        if mutationInProgress {
            await withCheckedContinuation { waiters.append($0) }
        } else { mutationInProgress = true }
    }

    private func releaseMutation() {
        if waiters.isEmpty { mutationInProgress = false }
        else { waiters.removeFirst().resume() }
    }

    private func rememberIndependent(_ snapshot: [DisplayDescriptor], onlyMissing: Bool = false) async throws {
        if history == nil { history = try await historyStore?.load() ?? DisplayHistory() }
        let original = history ?? DisplayHistory()
        let candidate = try capturedIndependent(snapshot, in: original, onlyMissing: onlyMissing)
        if candidate.displays != original.displays {
            try await historyStore?.save(candidate)
            history = candidate
            diagnostics?.record("history.independent-observed", displays: Array(candidate.displays.values))
        }
    }

    private func capturedIndependent(
        _ snapshot: [DisplayDescriptor], in original: DisplayHistory, onlyMissing: Bool = false
    ) throws -> DisplayHistory {
        var candidate = original
        let members = DisplayLayoutPlanner.mirrorMembers(in: snapshot)
        let offset = snapshot.first { $0.role == .main }.flatMap { candidate.displays[$0.id]?.frame }
        for display in snapshot where !members.contains(display.id) && display.isActive {
            if onlyMissing && candidate.displays[display.id] != nil { continue }
            var independent = display
            independent.frame = try independent.frame.translated(
                byX: Int64(offset?.x ?? 0), byY: Int64(offset?.y ?? 0))
            candidate.displays[display.id] = independent
        }
        return candidate
    }

    private func mutate(
        _ plan: @Sendable ([DisplayDescriptor]) throws -> [DisplayConfigurationOperation]
    ) async throws {
        try await DisplayDiagnostics.$correlationID.withValue(UUID().uuidString) {
            do { try await performMutation(plan) }
            catch {
                diagnostics?.record("transition.failed", details: ["error": String(describing: error)])
                throw error
            }
        }
    }

    private func performMutation(
        _ plan: @Sendable ([DisplayDescriptor]) throws -> [DisplayConfigurationOperation]
    ) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        let snapshot = try await driver.readDisplays()
        diagnostics?.record("transition.before", displays: snapshot)
        let baseOperations = try plan(snapshot)
        guard !baseOperations.isEmpty else {
            try await rememberIndependent(snapshot, onlyMissing: true)
            diagnostics?.record("transition.noop", displays: snapshot)
            return
        }
        if history == nil { history = try await historyStore?.load() ?? DisplayHistory() }
        let candidate = try capturedIndependent(snapshot, in: history ?? DisplayHistory())
        let operations = try DisplayLayoutPlanner.preservingIndependentState(
            baseOperations, displays: snapshot, remembered: candidate.displays
        )
        diagnostics?.record("transition.plan", operations: operations,
            details: ["rememberedCount": String(candidate.displays.count)])
        try Task.checkCancellation()
        do { try await driver.apply(operations) }
        catch {
            if let actual = try? await driver.readDisplays() {
                diagnostics?.record("transition.failed-readback", displays: actual)
            }
            throw error
        }
        // A successful native transaction owns the candidate; failure never adopts its history.
        history = candidate
        let actual: [DisplayDescriptor]
        do { actual = try await driver.readDisplays() }
        catch {
            // Preserve valid history even when a successful apply cannot be observed afterwards.
            do { try await historyStore?.save(candidate) }
            catch { diagnostics?.record("transition.history-save-failed", details: ["error": String(describing: error)]) }
            throw DisplayManagerError.systemFailure("Display configuration applied, but readback failed: \(error)")
        }
        diagnostics?.record("transition.after", displays: actual)
        do { try await historyStore?.save(candidate) }
        catch { throw DisplayManagerError.systemFailure("Display configuration applied, but history could not be saved: \(error)") }
        diagnostics?.record("transition.completed", displays: actual)
    }
}
