import AppKit
import Combine
import Foundation
import MacUtilsCore
import MacUtilsSystem

enum StorageBrowserMode: String, CaseIterable {
    case hierarchy
    case largestFiles
}

struct StorageTrashSelection: Identifiable {
    let snapshotID: UUID
    let nodeIDs: [Int]
    let paths: [String]
    var id: UUID { snapshotID }
}

enum StorageInformationSheet: String, Identifiable {
    case management
    case access
    var id: Self { self }
}

/// A catalog's object count is an estimate, not a known completion boundary.
struct StorageProgressStatus {
    let elapsedSeconds: Int
    let averageItemsPerSecond: Double?
    let approximateFraction: Double?

    init(progress: StorageScanProgress?, startedAt: Date?, now: Date) {
        let elapsed = max(0, startedAt.map { now.timeIntervalSince($0) } ?? 0)
        elapsedSeconds = Int(elapsed)
        averageItemsPerSecond = elapsed >= 1 && (progress?.visitedItems ?? 0) > 0
            ? Double(progress?.visitedItems ?? 0) / elapsed : nil
        if let progress, progress.phase == .volumeCatalog,
           let estimate = progress.estimatedTotalItems, estimate > 0 {
            approximateFraction = min(0.99, max(0, Double(progress.visitedItems) / Double(estimate)))
        } else { approximateFraction = nil }
    }
}

@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var volumes: [StorageVolume] = []
    @Published private(set) var grants: [StorageGrant] = []
    @Published private(set) var selectedGrantID: UUID?
    @Published private(set) var snapshot: StorageSnapshot?
    @Published private(set) var isCached = false
    @Published private(set) var isScanning = false
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var isPreparingPresentation = false
    @Published private(set) var progress: StorageScanProgress?
    @Published private(set) var scanStartedAt: Date?
    @Published var informationSheet: StorageInformationSheet?
    @Published private(set) var error: String? {
        didSet { if error == nil { errorTitle = nil } }
    }
    @Published private(set) var errorTitle: String?
    @Published private(set) var notice: String?
    @Published private(set) var folderID = 0
    @Published private(set) var visibleNodes: [StorageTreeRow] = []
    @Published private(set) var mapNodes: [StorageItemReference] = []
    @Published private(set) var childPages: [Int: StorageTreePage] = [:]
    @Published private(set) var expandedIDs: Set<Int> = [0]
    @Published private(set) var loadingChildren: Set<Int> = []
    @Published private(set) var treeUnavailable = false
    @Published private(set) var isResolvingSelection = false
    @Published var selection: Set<Int> = [] { didSet { resolveSelection() } }
    @Published private(set) var pendingTrash: StorageTrashSelection?
    @Published var metric: StorageSizeMetric = .allocated {
        didSet { if metric != oldValue { updatePresentation() } }
    }
    @Published var browserMode: StorageBrowserMode = .hierarchy {
        didSet { if browserMode != oldValue { updatePresentation() } }
    }
    @Published var sortDescending = true {
        didSet { if sortDescending != oldValue { updatePresentation() } }
    }
    @Published var showsMap = false

    private let service: any StorageManaging
    private let volumeProvider: @Sendable () async -> [StorageVolume]
    private var volumeGeneration: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var presentationGeneration: UInt64 = 0
    private var presentation: Task<Void, Never>?
    // Requests may replace each other after pages are cleared; carry their reload target forward.
    private var presentationPageTargets: [Int: Int] = [:]
    private var childOperations: [Int: Task<Void, Never>] = [:]
    private var navigationOperations: [UUID: Task<Void, Never>] = [:]
    private var selectionOperation: Task<Void, Never>?
    private var selectionGeneration: UInt64 = 0
    private var rowsByID: [Int: StorageTreeRow] = [:]
    private var references: [Int: StorageItemReference] = [:]
    private var hiddenTrashedIDs: Set<Int> = []
    private var hiddenTrashedPaths: [String] = []
    private var hiddenPageCounts: [Int: Int] = [:]
    @Published private(set) var hasStaleTrashResults = false
    private var releaseOperations: [Task<Void, Never>] = []
    private static let pageSize = 200
    private var hasStarted = false
    var text = AppText(language: .system)

    init(service: any StorageManaging = StorageService(),
         volumeProvider: @escaping @Sendable () async -> [StorageVolume] = { await StorageVolumeCatalog.mountedVolumes() }) {
        self.service = service
        self.volumeProvider = volumeProvider
    }

    var selectedGrant: StorageGrant? { grants.first { $0.id == selectedGrantID } }
    var selectedVolume: StorageVolume? { volumes.first { $0.url.standardizedFileURL.path == selectedGrant?.path } }

    func locationName(_ grant: StorageGrant) -> String {
        volumes.first { $0.url.standardizedFileURL.path == grant.path }?.name ?? grant.path
    }

    func reloadVolumes() async {
        volumeGeneration &+= 1
        let token = volumeGeneration
        let loaded = await volumeProvider()
        guard token == volumeGeneration else { return }
        volumes = loaded
    }
    var selectedNodes: [StorageItemReference] {
        guard let snapshot else { return [] }
        return selection.sorted().compactMap { knownReference(id: $0, in: snapshot) }
    }
    var focusedRow: StorageTreeRow? { rowsByID[folderID] }
    var rootRow: StorageTreeRow? { rowsByID[0] }
    var breadcrumbs: [StorageTreeRow] {
        var result: [StorageTreeRow] = []; var current = focusedRow; var seen = Set<Int>()
        while let row = current, seen.insert(row.id).inserted {
            result.append(row); current = row.parentID.flatMap { rowsByID[$0] }
        }
        return result.reversed()
    }
    var omittedMapBytes: UInt64 {
        guard browserMode == .hierarchy, let row = focusedRow else { return 0 }
        let total = row.bytes(for: metric)
        let shown = mapNodes.reduce(UInt64(0)) { partial, item in
            let sum = partial.addingReportingOverflow(item.bytes(for: metric))
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        return total > shown ? total - shown : 0
    }
    var currentName: String {
        guard let snapshot else { return selectedGrant?.name ?? "" }
        return folderID == 0 ? selectedVolume?.name ?? snapshot.root?.name ?? ""
            : focusedRow?.name ?? snapshot.root?.name ?? ""
    }
    var canTrash: Bool {
        !hasStaleTrashResults && !isScanning && !isLoading && !isMutating && !isPreparingPresentation && !isResolvingSelection
            && !selectedNodes.isEmpty && selectedNodes.count == selection.count
            && selectedNodes.allSatisfy { !$0.relativePath.isEmpty && !$0.isInsidePackage }
    }
    var canOpenCurrentFolderInFinder: Bool {
        !isMutating && !isPreparingPresentation && focusedRow?.kind == .directory
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let token = generation
        await waitForReleases()
        guard hasStarted, token == generation else { return }
        isLoading = true
        defer { if token == generation { isLoading = false } }
        await reloadVolumes()
        guard token == generation else { return }
        do {
            let loaded = try await service.grants()
            guard token == generation else { return }
            grants = loaded
            if let selected = grants.first(where: { $0.id == selectedGrantID }) ?? grants.first { await load(selected) }
        } catch { if token == generation { report(error) } }
    }

    func chooseFolder() {
        presentSelectionPanel(directory: nil, disk: false)
    }

    func chooseDisk(_ volume: StorageVolume) {
        guard !isMutating else { return }
        #if APP_STORE
        presentSelectionPanel(directory: volume.url, disk: true)
        #else
        Task { [weak self] in await self?.selectFolder(volume.url) }
        #endif
    }

    private func presentSelectionPanel(directory: URL?, disk: Bool) {
        guard !isMutating else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        panel.title = text(disk ? "storage.chooseDisk" : "storage.choose")
        panel.prompt = text("storage.scan")
        panel.message = text(disk ? "storage.diskGrant.message" : "storage.choose.message")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in await self?.selectFolder(url) }
        }
    }

    func selectFolder(_ url: URL) async {
        guard !isMutating else { return }
        cancelPending()
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let grant = try await service.selectFolder(url)
            let updated = try await service.grants()
            guard token == generation else { return }
            grants = updated
            await load(grant)
            if token == generation, snapshot == nil, error == nil { refresh() }
        } catch { if token == generation { report(error) } }
    }

    func selectGrant(_ id: UUID) {
        guard !isMutating, let grant = grants.first(where: { $0.id == id }), id != selectedGrantID else { return }
        cancelPending()
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            self.isLoading = true
            defer { if token == self.generation { self.isLoading = false } }
            await self.load(grant)
        }
    }

    private func load(_ grant: StorageGrant) async {
        let token = generation
        selectedGrantID = grant.id
        replaceSnapshot(nil, cached: false)
        await waitForReleases()
        guard token == generation else { return }
        error = nil; notice = nil; progress = nil
        isCached = false
        do {
            let cached = try await service.cachedSnapshot(for: grant)
            guard token == generation, selectedGrantID == grant.id else {
                if let cached { retire(cached.id) }
                return
            }
            var superseded = false
            var statusFailure: (any Error)?
            if let cached {
                do { superseded = try await service.isSnapshotSuperseded(cached) }
                catch { superseded = true; statusFailure = error }
            }
            guard token == generation, selectedGrantID == grant.id else {
                if let cached { retire(cached.id) }
                return
            }
            replaceSnapshot(cached, cached: cached != nil)
            hasStaleTrashResults = superseded
            if let statusFailure { report(statusFailure) }
        } catch { if token == generation { report(error) } }
    }

    func refresh() {
        guard let grant = selectedGrant, !isMutating else { return }
        cancelPending()
        let token = generation
        isScanning = true; scanStartedAt = Date(); progress = nil; error = nil; notice = nil
        let service = service
        operation = Task { [weak self] in
            do {
                let progressHandler: @Sendable (StorageScanProgress) async -> Void = { [weak self] progress in
                    await self?.receive(progress, token: token)
                }
                let result = try await service.scan(grant, progress: progressHandler)
                let roster: Result<[StorageGrant], any Error>
                do { roster = .success(try await service.grants()) }
                catch { roster = .failure(error) }
                guard let self else { await service.releaseTree(snapshotID: result.id); return }
                guard token == self.generation else { self.retire(result.id); return }
                switch roster {
                case let .success(grants): self.grants = grants
                case let .failure(error): self.report(error)
                }
                self.isScanning = false; self.scanStartedAt = nil; self.operation = nil
                self.replaceSnapshot(result, cached: false)
            } catch {
                guard let self, token == self.generation else { return }
                self.isScanning = false; self.scanStartedAt = nil; self.operation = nil
                if error is CancellationError { self.notice = self.text("storage.cancelled") }
                else { self.report(error) }
            }
        }
    }

    private func receive(_ progress: StorageScanProgress, token: UInt64) {
        guard token == generation, isScanning else { return }
        self.progress = progress
    }

    func cancelScan() {
        guard isScanning else { return }
        cancelPending()
        notice = text("storage.cancelled")
    }

    func stop() {
        cancelPending()
        replaceSnapshot(nil, cached: false)
        hasStarted = false
    }

    func waitForScan() async { await operation?.value; await waitForPresentation() }

    func waitForPresentation() async {
        while true {
            let token = presentationGeneration
            await presentation?.value
            for work in Array(navigationOperations.values) { await work.value }
            for work in Array(childOperations.values) { await work.value }
            await selectionOperation?.value
            if token == presentationGeneration && childOperations.isEmpty && navigationOperations.isEmpty { break }
        }
        await waitForReleases()
    }

    private func cancelPending() {
        generation &+= 1
        pendingTrash = nil
        operation?.cancel(); operation = nil
        isScanning = false; scanStartedAt = nil; isLoading = false; progress = nil
    }

    func openFolder(_ id: Int, in expectedSnapshotID: UUID? = nil) {
        guard let snapshot, let row = rowsByID[id], row.kind == .directory || row.kind == .package,
              expectedSnapshotID == nil || expectedSnapshotID == snapshot.id,
              !isMutating, !isLoading, !isPreparingPresentation, !treeUnavailable else { return }
        if id != 0, row.parentID == nil, let item = references[id] {
            presentation = Task { [weak self] in
                guard let self, let resolved = await self.expand(relativePath: item.relativePath),
                      self.snapshot?.id == snapshot.id else { return }
                self.openFolder(resolved, in: snapshot.id)
            }
            return
        }
        showsMap = true
        folderID = id; selection = []; browserMode = .hierarchy
        expandedIDs.insert(id)
        updatePresentation(resetPages: false)
    }

    func selectItems(_ ids: Set<Int>, in snapshotID: UUID) {
        guard let snapshot, snapshot.id == snapshotID, !isPreparingPresentation,
              ids.allSatisfy({ !hiddenTrashedIDs.contains($0)
                  && (rowsByID[$0] != nil || references[$0] != nil || snapshot.itemReference(id: $0) != nil) }) else { return }
        selection = ids
    }

    private func updatePresentation(resetPages: Bool = true, restoringCounts: [Int: Int]? = nil) {
        presentationGeneration &+= 1
        presentation?.cancel()
        let token = presentationGeneration
        guard let snapshot else {
            visibleNodes = []; mapNodes = []; presentationPageTargets = [:]
            isPreparingPresentation = false; return
        }
        isPreparingPresentation = true
        let requestedCounts = restoringCounts ?? (resetPages ? childPages.mapValues { $0.rows.count } : [:])
        let loadedCounts = presentationPageTargets.merging(requestedCounts, uniquingKeysWith: max)
        presentationPageTargets = loadedCounts
        // Every generation owns its pending queries, even when completed pages are retained.
        cancelChildren()
        if resetPages { childPages = [:] }
        let folder = folderID; let mode = browserMode
        presentation = Task { [weak self] in
            guard let self else { return }
            if !self.treeUnavailable {
                let parents = self.expandedIDs.union([0, folder]).union(loadedCounts.keys).sorted()
                for parent in parents {
                    await self.loadChildren(parent, append: false, snapshotID: snapshot.id, token: token)
                    while self.children(of: parent).count < (loadedCounts[parent] ?? 0),
                          self.hasMoreChildren(of: parent), token == self.presentationGeneration,
                          self.snapshot?.id == snapshot.id {
                        let previousCount = self.children(of: parent).count
                        await self.loadChildren(parent, append: true, snapshotID: snapshot.id, token: token)
                        guard self.children(of: parent).count > previousCount else { break }
                    }
                    guard token == self.presentationGeneration, self.snapshot?.id == snapshot.id else { return }
                }
            }
            await self.prepareMap(snapshot: snapshot, folder: folder, mode: mode, token: token)
            guard token == self.presentationGeneration, self.snapshot?.id == snapshot.id else { return }
            self.presentationPageTargets = [:]
            self.isPreparingPresentation = false
        }
    }

    func row(id: Int) -> StorageTreeRow? { rowsByID[id] }
    func displayPath(for id: Int) -> String {
        guard let snapshot else { return "" }
        if let item = knownReference(id: id, in: snapshot) {
            return URL(fileURLWithPath: snapshot.rootPath).appending(path: item.relativePath).path
        }
        var components: [String] = []; var current = rowsByID[id]; var seen = Set<Int>()
        while let row = current, row.id != 0, seen.insert(row.id).inserted {
            components.append(row.name); current = row.parentID.flatMap { rowsByID[$0] }
        }
        return URL(fileURLWithPath: snapshot.rootPath).appending(path: components.reversed().joined(separator: "/")).path
    }
    func children(of parentID: Int) -> [StorageTreeRow] { childPages[parentID]?.rows ?? [] }
    func hasMoreChildren(of parentID: Int) -> Bool { childPages[parentID]?.hasMore == true }

    func expandFolder(_ id: Int, in snapshotID: UUID) {
        guard snapshot?.id == snapshotID, !treeUnavailable, !isMutating else { return }
        expandedIDs.insert(id)
        let key = UUID()
        navigationOperations[key] = Task { [weak self] in
            guard let self else { return }
            await self.loadChildren(id, append: false, snapshotID: snapshotID, token: self.presentationGeneration)
            self.navigationOperations[key] = nil
        }
    }

    func collapseFolder(_ id: Int, in snapshotID: UUID) {
        guard snapshot?.id == snapshotID else { return }
        expandedIDs.remove(id)
    }

    func loadMoreChildren(of id: Int, in snapshotID: UUID) {
        guard snapshot?.id == snapshotID, !loadingChildren.contains(id) else { return }
        let key = UUID()
        navigationOperations[key] = Task { [weak self] in
            guard let self else { return }
            await self.loadChildren(id, append: true, snapshotID: snapshotID, token: self.presentationGeneration)
            if self.folderID == id, let snapshot = self.snapshot {
                await self.prepareMap(snapshot: snapshot, folder: id, mode: self.browserMode, token: self.presentationGeneration)
            }
            self.navigationOperations[key] = nil
        }
    }

    /// Resolves a saved path through indexed pages. It never starts a filesystem scan.
    @discardableResult
    func expand(relativePath: String) async -> Int? {
        guard let snapshot, !treeUnavailable, !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard relativePath.isEmpty || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let token = presentationGeneration
        var parent = 0
        for name in relativePath.isEmpty ? [] : components {
            expandedIDs.insert(parent)
            await loadChildren(parent, append: false, snapshotID: snapshot.id, token: token)
            while snapshot.id == self.snapshot?.id, token == presentationGeneration,
                  !children(of: parent).contains(where: { $0.name == name }), hasMoreChildren(of: parent) {
                let previousCount = children(of: parent).count
                await loadChildren(parent, append: true, snapshotID: snapshot.id, token: token)
                guard children(of: parent).count > previousCount else { break }
            }
            guard snapshot.id == self.snapshot?.id, token == presentationGeneration,
                  let child = children(of: parent).first(where: { $0.name == name }) else { return nil }
            parent = child.id
        }
        if rowsByID[parent]?.isExpandable == true || parent == 0 {
            expandedIDs.insert(parent)
            await loadChildren(parent, append: false, snapshotID: snapshot.id, token: token)
        }
        return snapshot.id == self.snapshot?.id && token == presentationGeneration ? parent : nil
    }

    func focus(relativePath: String) async {
        guard let id = await expand(relativePath: relativePath), let snapshot else { return }
        openFolder(id, in: snapshot.id)
        await waitForPresentation()
    }

    func select(relativePath: String) async {
        guard let id = await expand(relativePath: relativePath), let snapshot else { return }
        selectItems([id], in: snapshot.id)
        await selectionOperation?.value
    }

    private func loadChildren(_ parent: Int, append: Bool, snapshotID: UUID, token: UInt64) async {
        guard let snapshot, snapshot.id == snapshotID, token == presentationGeneration, !treeUnavailable else { return }
        if let existing = childOperations[parent] { await existing.value; return }
        if !append && childPages[parent] != nil { return }
        let prior = append ? childPages[parent] : nil
        if append && prior?.hasMore != true { return }
        let offset = (prior?.rows.count ?? 0) + (append ? hiddenPageCounts[parent, default: 0] : 0)
        if rowsByID[parent]?.childCount == 0 {
            childPages[parent] = StorageTreePage(rows: [], offset: 0, totalCount: 0)
            return
        }
        let metric = metric; let descending = sortDescending; let service = service
        loadingChildren.insert(parent)
        let work = Task { [weak self] in
            do {
                let page = try await service.treeChildren(parentID: parent, in: snapshot, metric: metric,
                    descending: descending, offset: offset, limit: Self.pageSize)
                guard let self else { await service.releaseTree(snapshotID: snapshotID); return }
                guard self.snapshot?.id == snapshotID, token == self.presentationGeneration, !Task.isCancelled else {
                    self.retire(snapshotID); return
                }
                guard page.offset == offset, !page.rows.isEmpty || !page.hasMore else {
                    throw StorageServiceError.invalidData("The saved tree returned an invalid child page.")
                }
                let incoming = page.rows.filter { !self.hiddenTrashedIDs.contains($0.id) }
                self.hiddenPageCounts[parent] = (append ? self.hiddenPageCounts[parent, default: 0] : 0)
                    + page.rows.count - incoming.count
                let rows = (prior?.rows ?? []) + incoming
                self.childPages[parent] = StorageTreePage(rows: rows, offset: 0,
                    totalCount: page.totalCount - self.hiddenPageCounts[parent, default: 0])
                for row in incoming { self.rowsByID[row.id] = row }
            } catch {
                guard let self else { await service.releaseTree(snapshotID: snapshotID); return }
                guard self.snapshot?.id == snapshotID, token == self.presentationGeneration else { self.retire(snapshotID); return }
                if case StorageServiceError.treeUnavailable = error { self.treeUnavailable = true }
                else if !(error is CancellationError) { self.report(error) }
            }
            guard let self, self.snapshot?.id == snapshotID, token == self.presentationGeneration else { return }
            self.loadingChildren.remove(parent)
            self.childOperations[parent] = nil
        }
        childOperations[parent] = work
        await work.value
    }

    private func prepareMap(snapshot: StorageSnapshot, folder: Int, mode: StorageBrowserMode, token: UInt64) async {
        let candidates: [StorageItemReference]
        if mode == .largestFiles || treeUnavailable {
            candidates = snapshot.largestItems(metric: metric, limit: 200).filter {
                !hiddenTrashedIDs.contains($0.id) && !isHiddenTrashPath($0.relativePath)
            }
        } else {
            var result: [StorageItemReference] = []
            for row in children(of: folder).prefix(255) {
                do {
                    let item: StorageItemReference?
                    if let known = references[row.id] { item = known }
                    else { item = try await service.treeItem(id: row.id, in: snapshot) }
                    if let item {
                        result.append(item)
                    }
                } catch {
                    guard self.snapshot?.id == snapshot.id, token == presentationGeneration else { retire(snapshot.id); return }
                    report(error); break
                }
                guard self.snapshot?.id == snapshot.id, token == presentationGeneration, !Task.isCancelled else {
                    retire(snapshot.id); return
                }
            }
            candidates = result
        }
        guard self.snapshot?.id == snapshot.id, token == presentationGeneration else { retire(snapshot.id); return }
        let retained = selection.union([0, folder])
        references = references.filter { retained.contains($0.key) }
        for item in candidates { references[item.id] = item }
        mapNodes = candidates
        if mode == .hierarchy { visibleNodes = children(of: folder) }
        else {
            visibleNodes = candidates.map { item in
                StorageTreeRow(id: item.id, parentID: rowsByID[item.id]?.parentID, name: item.name, kind: item.kind,
                    totals: item.totals, childCount: rowsByID[item.id]?.childCount ?? 0,
                    isCloudPlaceholder: item.isCloudPlaceholder, isHardLinkDuplicate: item.isHardLinkDuplicate,
                    isIncomplete: item.isIncomplete, isInsidePackage: item.isInsidePackage)
            }
            for row in visibleNodes where rowsByID[row.id] == nil { rowsByID[row.id] = row }
        }
    }

    private func resolveSelection() {
        selectionGeneration &+= 1
        selectionOperation?.cancel(); selectionOperation = nil
        guard let snapshot else { isResolvingSelection = false; return }
        let missing = selection.sorted().filter { knownReference(id: $0, in: snapshot) == nil }
        guard !missing.isEmpty else { isResolvingSelection = false; return }
        let token = selectionGeneration; let service = service
        isResolvingSelection = true
        selectionOperation = Task { [weak self] in
            for id in missing {
                do {
                    let item = try await service.treeItem(id: id, in: snapshot)
                    guard let self else { await service.releaseTree(snapshotID: snapshot.id); return }
                    guard self.snapshot?.id == snapshot.id, token == self.selectionGeneration else { self.retire(snapshot.id); return }
                    if let item { self.references[id] = item }
                } catch {
                    guard let self else { await service.releaseTree(snapshotID: snapshot.id); return }
                    guard self.snapshot?.id == snapshot.id, token == self.selectionGeneration else { self.retire(snapshot.id); return }
                    if !(error is CancellationError) { self.report(error) }
                }
            }
            guard let self, self.snapshot?.id == snapshot.id, token == self.selectionGeneration else { return }
            self.isResolvingSelection = false
        }
    }

    private func replaceSnapshot(_ value: StorageSnapshot?, cached: Bool) {
        let oldID = snapshot?.id
        presentationGeneration &+= 1
        presentation?.cancel(); cancelChildren(); selectionOperation?.cancel()
        presentationPageTargets = [:]
        snapshot = value; selection = []; folderID = 0
        references = [:]; rowsByID = [:]; childPages = [:]; expandedIDs = [0]
        hiddenTrashedIDs = []; hiddenTrashedPaths = []; hiddenPageCounts = [:]; hasStaleTrashResults = false
        visibleNodes = []; mapNodes = []; isCached = cached
        treeUnavailable = value.map { $0.schemaVersion == 2 && $0.tree == nil } ?? false
        if let value, let root = value.root {
            rowsByID[0] = StorageTreeRow(id: 0, parentID: nil, name: root.name, kind: root.kind,
                totals: StorageTotals(logicalBytes: root.logicalBytes, allocatedBytes: root.allocatedBytes,
                    apparentBytes: root.apparentBytes, fileCount: root.fileCount),
                childCount: value.tree?.rootChildCount ?? value.nodes.filter { $0.parentID == 0 }.count,
                isCloudPlaceholder: root.isCloudPlaceholder, isIncomplete: root.isIncomplete)
            if value.schemaVersion < 3, let reference = value.itemReference(id: 0) { references[0] = reference }
        }
        if let oldID, oldID != value?.id { retire(oldID) }
        updatePresentation()
    }

    private func cancelChildren() {
        for work in childOperations.values { work.cancel() }
        for work in navigationOperations.values { work.cancel() }
        navigationOperations = [:]
        childOperations = [:]; loadingChildren = []
    }

    private func retire(_ id: UUID) {
        guard snapshot?.id != id else { return }
        let service = service
        releaseOperations.append(Task { [weak self] in
            guard self?.snapshot?.id != id else { return }
            await service.releaseTree(snapshotID: id)
        })
    }

    private func waitForReleases() async {
        while !releaseOperations.isEmpty {
            let releases = releaseOperations
            releaseOperations = []
            for work in releases { await work.value }
        }
    }

    private func knownReference(id: Int, in snapshot: StorageSnapshot) -> StorageItemReference? {
        guard !hiddenTrashedIDs.contains(id) else { return nil }
        let item = references[id] ?? (snapshot.schemaVersion < 3 ? snapshot.itemReference(id: id) : nil)
        return item.flatMap { isHiddenTrashPath($0.relativePath) ? nil : $0 }
    }

    private func isHiddenTrashPath(_ path: String) -> Bool {
        hiddenTrashedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func clearCache() async {
        guard !isMutating else { return }
        cancelPending(); isMutating = true
        defer { isMutating = false }
        do {
            try await service.clearCache()
            replaceSnapshot(nil, cached: false)
            await waitForReleases()
            notice = text("storage.cacheCleared"); error = nil
        } catch { report(error) }
    }

    func removeSelectedGrant() async {
        guard let grant = selectedGrant, !isMutating else { return }
        cancelPending(); isMutating = true
        defer { isMutating = false }
        do {
            try await service.removeGrant(grant)
            grants = try await service.grants()
            selectedGrantID = nil; replaceSnapshot(nil, cached: false)
            await waitForReleases()
            if let first = grants.first { await load(first) }
        } catch { report(error) }
    }

    func resetSavedLocations() async {
        guard !isMutating else { return }
        cancelPending(); isMutating = true
        defer { isMutating = false }
        do {
            try await service.resetSavedLocations()
            grants = []; selectedGrantID = nil; replaceSnapshot(nil, cached: false)
            await waitForReleases()
            error = nil; notice = text("storage.locationsReset")
        } catch { report(error) }
    }

    func revealSelection() async {
        guard let snapshot, let id = selection.sorted().first, !isMutating else { return }
        do {
            let item: StorageItemReference?
            if let known = knownReference(id: id, in: snapshot) { item = known }
            else { item = try await service.treeItem(id: id, in: snapshot) }
            guard self.snapshot?.id == snapshot.id else { retire(snapshot.id); return }
            if let item { try await service.reveal(item: item, in: snapshot) }
        }
        catch { report(error) }
    }

    func openCurrentFolderInFinder(in expectedSnapshotID: UUID? = nil) async {
        guard canOpenCurrentFolderInFinder, let snapshot,
              expectedSnapshotID == nil || expectedSnapshotID == snapshot.id else { return }
        do { try await service.openDirectory(nodeID: folderID, in: snapshot) }
        catch { report(error) }
    }

    func requestTrashConfirmation() {
        guard canTrash, let snapshot else { return }
        pendingTrash = StorageTrashSelection(snapshotID: snapshot.id,
            nodeIDs: selectedNodes.map(\.id), paths: selectedNodes.map {
                URL(fileURLWithPath: snapshot.rootPath).appending(path: $0.relativePath).path
            })
    }

    func cancelTrashConfirmation() { pendingTrash = nil }

    /// Called only with the exact snapshot/items captured by the confirmation dialog.
    func trashConfirmed(snapshotID: UUID, nodeIDs: [Int]) async {
        guard let snapshot, snapshot.id == snapshotID, !hasStaleTrashResults,
              !isScanning, !isLoading, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        let token = generation
        do {
            var items: [StorageItemReference] = []
            for id in Set(nodeIDs).sorted() {
                let item: StorageItemReference?
                if let known = knownReference(id: id, in: snapshot) { item = known }
                else { item = try await service.treeItem(id: id, in: snapshot) }
                guard let item, !item.relativePath.isEmpty, !item.isInsidePackage else {
                    throw StorageServiceError.unsafeItem("Select a non-root item outside package contents.")
                }
                items.append(item)
            }
            guard !items.isEmpty else { return }
            guard token == generation, self.snapshot?.id == snapshotID else { return }
            let result = try await service.trash(items: items, in: snapshot)
            guard token == generation, self.snapshot?.id == snapshotID else {
                if let updated = result.updatedSnapshot { retire(updated.id) }
                return
            }
            if !result.trashedNodeIDs.isEmpty {
                let removedRoots = Set(result.trashedNodeIDs)
                var removed = removedRoots
                // Only loaded rows are visited; entire removed subtrees stay absent in the new index.
                for row in rowsByID.values {
                    var current: StorageTreeRow? = row
                    var seen = Set<Int>()
                    while let ancestor = current, seen.insert(ancestor.id).inserted {
                        if removedRoots.contains(ancestor.id) { removed.insert(row.id); break }
                        current = ancestor.parentID.flatMap { rowsByID[$0] }
                    }
                }
                let movedPaths = items.filter { removedRoots.contains($0.id) }.map(\.relativePath)
                for item in references.values where movedPaths.contains(where: {
                    item.relativePath == $0 || item.relativePath.hasPrefix($0 + "/")
                }) { removed.insert(item.id) }
                let counts = childPages.mapValues { $0.rows.count }
                while removed.contains(folderID), let parent = rowsByID[folderID]?.parentID { folderID = parent }
                expandedIDs.subtract(removed)
                let retainedSelection = selection.subtracting(removed)
                presentationGeneration &+= 1
                presentation?.cancel(); cancelChildren(); selectionOperation?.cancel()
                presentationPageTargets = [:]
                rowsByID = rowsByID.filter { !removed.contains($0.key) }
                references = [:]
                if let updated = result.updatedSnapshot {
                    self.snapshot = updated
                    retire(snapshotID)
                    hiddenTrashedIDs = []; hiddenTrashedPaths = []; hiddenPageCounts = [:]; hasStaleTrashResults = false
                    childPages = [:]
                    // Refresh ancestor totals and canonical selection against the revised index.
                    for id in expandedIDs.union([0, folderID]).sorted() {
                        let item = try? await service.treeItem(id: id, in: updated)
                        guard token == generation, self.snapshot?.id == updated.id else { retire(updated.id); return }
                        if let item, let row = rowsByID[id] {
                            references[id] = item
                            let childCount: Int
                            if id == 0 {
                                childCount = updated.tree?.rootChildCount ?? updated.nodes.filter { $0.parentID == 0 }.count
                            } else if item.kind == .directory, updated.schemaVersion >= 3 {
                                childCount = item.unlistedChildCount
                            } else { childCount = row.childCount }
                            rowsByID[id] = StorageTreeRow(id: id, parentID: row.parentID, name: item.name,
                                kind: item.kind, totals: item.totals, childCount: childCount,
                                isCloudPlaceholder: item.isCloudPlaceholder, isHardLinkDuplicate: item.isHardLinkDuplicate,
                                isIncomplete: item.isIncomplete, isInsidePackage: item.isInsidePackage)
                        }
                    }
                    selection = retainedSelection
                    updatePresentation(restoringCounts: counts.filter { !removed.contains($0.key) })
                } else {
                    hiddenTrashedIDs.formUnion(removed)
                    hiddenTrashedPaths.append(contentsOf: movedPaths)
                    hasStaleTrashResults = true
                    for (parent, page) in childPages {
                        hiddenPageCounts[parent, default: 0] += page.rows.filter { removed.contains($0.id) }.count
                    }
                    childPages = childPages.filter { !removed.contains($0.key) }.mapValues { page in
                        let rows = page.rows.filter { !removed.contains($0.id) }
                        return StorageTreePage(rows: rows, offset: 0,
                            totalCount: max(rows.count, page.totalCount - (page.rows.count - rows.count)))
                    }
                    selection = retainedSelection
                    updatePresentation(resetPages: false)
                }
                notice = text.format("storage.trashed", result.trashedNodeIDs.count)
            }
            let failures = result.failures.map { failure in
                let name = items.first { $0.id == failure.nodeID }?.name ?? String(failure.nodeID)
                return "\(name): \(failure.message)"
            }
            error = (failures + [result.cacheInvalidationError].compactMap { $0 }).isEmpty ? nil
                : (failures + [result.cacheInvalidationError].compactMap { $0 }).joined(separator: "\n")
            if error != nil {
                errorTitle = [result.failures.isEmpty ? nil : text.format("storage.error.trashSummary", result.failures.count),
                    result.cacheInvalidationError == nil ? nil : text("storage.error.cacheSummary")]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        } catch { if token == generation, self.snapshot != nil { report(error) } }
    }

    private func report(_ failure: any Error) {
        error = text.error(failure)
        errorTitle = text.storageErrorSummary(failure)
    }
}
