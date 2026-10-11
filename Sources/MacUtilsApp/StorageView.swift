import AppKit
import MacUtilsCore
import MacUtilsSystem
import SwiftUI

struct StorageView: View {
    @ObservedObject var model: StorageModel
    let text: AppText
    @State private var showsIssues = false
    @State private var confirmsCacheClear = false
    @State private var confirmsLocationReset = false
    @State private var showsErrorDetails = false
    @State private var toolNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = model.error {
                HStack(alignment: .top) {
                Label(model.errorTitle ?? error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .lineLimit(3).help(error)
                Spacer()
                Button(text("storage.details")) { showsErrorDetails = true }.help(text("storage.details.help"))
                }
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            if model.hasStaleTrashResults {
                Text(text("storage.trash.stale")).font(.callout).foregroundStyle(.orange)
            }
            if model.isScanning { scanProgress }
            if let snapshot = model.snapshot {
                if model.isScanning {
                    // A previous result remains usable while refreshing. Give its browser a
                    // finite viewport so the table scrolls normally inside this native scroller.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            summary(snapshot)
                            snapshotBrowser(snapshot).frame(height: 540)
                        }
                    }.frame(minHeight: 0, maxHeight: .infinity)
                } else {
                    summary(snapshot)
                    snapshotBrowser(snapshot)
                }
            } else {
                ScrollView {
                ContentUnavailableView {
                    Label(text(model.isScanning ? "storage.scanning" : "storage.empty.title"), systemImage: "internaldrive")
                } description: {
                    Text(text(model.isScanning ? "storage.scanning.body"
                        : model.selectedGrant == nil ? "storage.empty.body" : "storage.noSnapshot"))
                } actions: {
                    if model.selectedGrant == nil {
                        HStack {
                            diskSelector
                            Button(text("storage.choose")) { model.chooseFolder() }
                                .help(text("storage.choose.help"))
                        }
                    } else if !model.isScanning {
                        Button(text("storage.scan")) { model.refresh() }.help(text("storage.scan.help"))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            nativeTools
        }
        .padding(14)
        .accessibilityIdentifier("storage-utility")
        .task { model.text = text; await model.start() }
        .onChange(of: text.language) { _, _ in model.text = text }
        .sheet(item: Binding(get: { model.pendingTrash }, set: { if $0 == nil { model.cancelTrashConfirmation() } })) {
            pending in trashConfirmation(pending)
        }
        .sheet(item: $model.informationSheet) { sheet in
            switch sheet {
            case .management: managementSheet
            case .access: accessSheet
            }
        }
        .sheet(isPresented: $showsIssues) { issuesSheet }
        .sheet(isPresented: $showsErrorDetails) {
            VStack(alignment: .leading, spacing: 14) {
                Text(text("storage.details")).font(.title2.bold())
                ScrollView { Text(model.error ?? "").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                Button(text("storage.close")) { showsErrorDetails = false }.keyboardShortcut(.cancelAction)
                    .help(text("storage.close.help"))
            }.padding(20).frame(width: 620, height: 440)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(text("storage.title")).font(.largeTitle.bold())
                Spacer()
                if model.isLoading || model.isMutating { ProgressView().controlSize(.small) }
                diskSelector
                Button(text("storage.choose")) { model.chooseFolder() }
                    .help(text("storage.choose.help"))
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isMutating).accessibilityIdentifier("storage-choose")
                Button(text("storage.refresh")) { model.refresh() }
                    .help(text("storage.refresh.help"))
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.selectedGrant == nil || model.isScanning || model.isLoading || model.isMutating)
                    .accessibilityIdentifier("storage-refresh")
            }
            HStack {
                if !model.grants.isEmpty {
                    Picker(text("storage.location"), selection: Binding(
                        get: { model.selectedGrantID },
                        set: { if let id = $0 { model.selectGrant(id) } }
                    )) {
                        ForEach(model.grants) { grant in
                            Text(model.locationName(grant)).tag(Optional(grant.id))
                        }
                    }
                    .disabled(model.isMutating).help(text("storage.location.help")).accessibilityIdentifier("storage-root-picker")
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text("storage.description")).foregroundStyle(.secondary)
                    Spacer()
                }
                Button(text("storage.access")) { model.informationSheet = .access }
                    .fixedSize().help(text("storage.access.help"))
                    .accessibilityIdentifier("storage-disk-access")
                Button(text("storage.manage")) { model.informationSheet = .management }
                    .fixedSize().disabled(model.isMutating).help(text("storage.manage.help"))
                    .accessibilityLabel(text("storage.manageCache"))
                    .accessibilityIdentifier("storage-management")
            }
        }
    }

    private var diskSelector: some View {
        Menu {
            if model.volumes.isEmpty {
                Text(text("storage.noDisks"))
            }
            ForEach(model.volumes) { volume in
                Button {
                    model.chooseDisk(volume)
                } label: {
                    if let total = volume.totalBytes {
                        Text("\(volume.name) · \(StorageFormatting.bytes(total, text: text))")
                    } else { Text(volume.name) }
                }
                .help(text.format("storage.disk.help", volume.name))
            }
            Divider()
            Button(text("storage.refreshDisks")) { Task { await model.reloadVolumes() } }
                .help(text("storage.refreshDisks.help"))
        } label: {
            Label(text("storage.chooseDisk"), systemImage: "internaldrive")
        }
        .fixedSize().disabled(model.isMutating)
        .help(text("storage.chooseDisk.help"))
        .accessibilityIdentifier("storage-choose-disk")
    }

    private var scanProgress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = StorageProgressStatus(progress: model.progress, startedAt: model.scanStartedAt, now: context.date)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(text(model.progress.map { "storage.phase.\($0.phase.rawValue)" }
                            ?? "storage.phase.preparing"))
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(text.format("storage.progress.elapsed", StorageFormatting.duration(status.elapsedSeconds)))
                            .monospacedDigit()
                    }
                    if let fraction = status.approximateFraction {
                        HStack(spacing: 8) {
                            ProgressView(value: fraction).frame(maxWidth: 150)
                            Text(text.format("storage.progress.approximate", fraction
                                .formatted(.percent.locale(Locale(identifier: text.language.resourceCode))
                                    .precision(.fractionLength(0)))))
                        }.help(text("storage.progress.estimate.help"))
                    }
                    HStack(spacing: 12) {
                        Text(text.format("storage.progress.count", (model.progress?.visitedItems ?? 0)
                            .formatted(.number.locale(Locale(identifier: text.language.resourceCode)))))
                        if let rate = status.averageItemsPerSecond {
                            Text(text.format("storage.progress.rate", rate
                                .formatted(.number.locale(Locale(identifier: text.language.resourceCode))
                                    .precision(.fractionLength(0)))))
                        }
                    }.font(.caption).monospacedDigit()
                    Text(text.format("storage.progress.sizes",
                        StorageFormatting.bytes(model.progress?.logicalBytes ?? 0, text: text),
                        StorageFormatting.bytes(model.progress?.allocatedBytes ?? 0, text: text)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.progress?.currentPath ?? model.selectedGrant?.path ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(model.progress?.currentPath ?? model.selectedGrant?.path ?? "")
                }
                Button(text("common.cancel")) { model.cancelScan() }
                    .help(text("storage.cancel.help"))
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("storage-cancel")
            }
            .padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func summary(_ snapshot: StorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                stat(text("storage.logical"), StorageFormatting.bytes(snapshot.root?.logicalBytes ?? 0, text: text)).help(text("storage.logical.help"))
                stat(text("storage.allocated"), StorageFormatting.bytes(snapshot.root?.allocatedBytes ?? 0, text: text)).help(text("storage.allocated.help"))
                stat(text("storage.files"), (snapshot.root?.fileCount ?? 0)
                    .formatted(.number.locale(Locale(identifier: text.language.resourceCode))))
                    .help(text("storage.files.help"))
                Spacer()
                if let volume = snapshot.volume {
                    stat(text("storage.volumeFree"), volume.availableBytes.map { StorageFormatting.bytes($0, text: text) } ?? "—").help(text("storage.volumeFree.help"))
                    stat(text("storage.volumeTotal"), volume.totalBytes.map { StorageFormatting.bytes($0, text: text) } ?? "—").help(text("storage.volumeTotal.help"))
                }
            }
            HStack {
                Label(text(model.isCached ? "storage.cached" : "storage.completed"),
                      systemImage: model.isCached ? "clock.arrow.circlepath"
                        : snapshot.isComplete ? "checkmark.circle" : "info.circle")
                    .help(text(model.isCached ? "storage.cached.help" : "storage.completed.help"))
                Text(snapshot.scannedAt, format: .dateTime.year().month().day().hour().minute())
                if !snapshot.issues.isEmpty || snapshot.omittedIssueCount > 0 {
                    Button {
                        showsIssues = true
                    } label: {
                        Label(text.format("storage.incomplete", snapshot.issues.count + snapshot.omittedIssueCount),
                              systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.link).foregroundStyle(.orange).help(text("storage.incomplete.help")).accessibilityIdentifier("storage-incomplete")
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            if snapshot.hasUnverifiedCoverage {
                HStack(alignment: .top, spacing: 8) {
                    Label(text("storage.catalogCoverage"), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(text("storage.access")) { model.informationSheet = .access }
                        .help(text("storage.access.help")).fixedSize()
                }
            } else if !snapshot.isComplete && snapshot.issues.isEmpty && snapshot.omittedIssueCount == 0 {
                Text(text("storage.partialCoverage")).font(.caption).foregroundStyle(.secondary)
            }
            Text(text("storage.sizeNote")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    @ViewBuilder
    private func snapshotBrowser(_ snapshot: StorageSnapshot) -> some View {
        browser(snapshot)
            .allowsHitTesting(!model.isPreparingPresentation)
            .overlay {
                if model.isPreparingPresentation { ProgressView() }
            }
    }

    private func browser(_ snapshot: StorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(model.breadcrumbs) { node in
                            if node.id != 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                            Button(node.id == 0 ? model.selectedVolume?.name ?? node.name : node.name) {
                                model.openFolder(node.id, in: snapshot.id)
                            }.help(text("storage.breadcrumb.help")).buttonStyle(.link).lineLimit(1)
                        }
                    }
                }
                Button(text("storage.revealFolder")) { Task { await model.openCurrentFolderInFinder(in: snapshot.id) } }
                    .disabled(!model.canOpenCurrentFolderInFinder).help(text("storage.revealFolder.help"))
                Picker(text("storage.metric"), selection: $model.metric) {
                    Text(text("storage.allocated")).tag(StorageSizeMetric.allocated)
                    Text(text("storage.logical")).tag(StorageSizeMetric.logical)
                }.frame(width: 240).help(text("storage.metric.help")).accessibilityIdentifier("storage-metric")
            }.frame(height: 28)
            HStack {
                Picker(text("storage.browser"), selection: $model.browserMode) {
                    Text(text("storage.hierarchy")).tag(StorageBrowserMode.hierarchy)
                    Text(text("storage.largest")).tag(StorageBrowserMode.largestFiles)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220).help(text("storage.browser.help"))
                Spacer()
                Picker(text("storage.tree.order"), selection: Binding(
                    get: { model.browserMode == .largestFiles ? true : model.sortDescending },
                    set: { if model.browserMode == .hierarchy { model.sortDescending = $0 } }
                )) {
                    Text(text("storage.tree.descending")).tag(true)
                    Text(text("storage.tree.ascending")).tag(false)
                }.frame(width: 260).help(text("storage.tree.order.help"))
                    .disabled(model.browserMode == .largestFiles)
                Toggle(text("storage.tree.showMap"), isOn: $model.showsMap)
                    .toggleStyle(.checkbox).fixedSize().help(text("storage.tree.showMap.help"))
            }.fixedSize(horizontal: false, vertical: true)
            if model.treeUnavailable {
                Text(text("storage.tree.legacy")).font(.callout).foregroundStyle(.secondary)
            }
            if model.showsMap {
                VSplitView {
                    treePanel(snapshot)
                    mapPanel(snapshot)
                }
            } else { treePanel(snapshot) }
            selectionDetails(snapshot)
        }
    }

    private func treePanel(_ snapshot: StorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text(model.browserMode == .hierarchy ? "storage.tree.help" : "storage.largest.limit"))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            StorageTreeView(model: model, snapshotID: snapshot.id, text: text)
                .frame(minHeight: 140, maxHeight: .infinity)
        }.frame(minHeight: 160, idealHeight: 300, maxHeight: .infinity)
    }

    private func mapPanel(_ snapshot: StorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text(model.browserMode == .hierarchy ? "storage.map.hierarchy" : "storage.map.largest"))
                .font(.caption).foregroundStyle(.secondary)
            StorageMapView(nodes: model.mapNodes, metric: model.metric, selection: model.selection, text: text,
                omittedBytes: model.omittedMapBytes,
                onSelect: { model.selectItems([$0], in: snapshot.id) },
                onOpen: { model.openFolder($0, in: snapshot.id) })
                .frame(minHeight: 60, idealHeight: 80, maxHeight: .infinity).clipped()
        }.frame(minHeight: 80, idealHeight: 100, maxHeight: .infinity)
    }

    private func selectionDetails(_ snapshot: StorageSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let node = model.selectedNodes.first {
                    Text(model.selectedNodes.count == 1 ? node.name : text.format("storage.selected", model.selectedNodes.count))
                        .font(.headline).lineLimit(1)
                    Text(URL(fileURLWithPath: snapshot.rootPath).appending(path: node.relativePath).path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    if node.isHardLinkDuplicate { Text(text("storage.hardlink")).font(.caption).foregroundStyle(.secondary) }
                    if node.isHardLinkDuplicate {
                        Text(text.format("storage.apparent", StorageFormatting.bytes(node.apparentBytes, text: text)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if node.isCloudPlaceholder { Text(text("storage.cloud")).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(text("storage.selectHint")).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let node = model.selectedNodes.first, model.selectedNodes.count == 1,
               node.kind == .directory || node.kind == .package {
                Button(text("storage.openFolder")) { model.openFolder(node.id, in: snapshot.id) }
                    .disabled(model.isScanning || model.isLoading).help(text("storage.openFolder.help"))
            }
            if model.selectedNodes.contains(where: \.isInsidePackage) {
                Text(text("storage.tree.packageProtected")).font(.caption).foregroundStyle(.secondary)
            }
            Button(text("storage.reveal")) { Task { await model.revealSelection() } }
                .help(text("storage.reveal.help"))
                .disabled(model.selection.isEmpty || model.isMutating)
            Button(text("storage.trash"), role: .destructive) {
                model.requestTrashConfirmation()
            }.disabled(!model.canTrash).help(text("storage.trash.help")).accessibilityIdentifier("storage-trash")
        }
        .frame(minHeight: 44)
    }

    private var nativeTools: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Button(text("storage.nativeStorage")) {
                    _ = StorageNativeTools.openStorageSettings()
                    toolNotice = text("storage.nativeRoute")
                }.help(text("storage.nativeStorage.help"))
                Button(text("storage.downloads")) {
                    if !StorageNativeTools.openDownloads() { toolNotice = text("storage.toolFailed") }
                }.help(text("storage.downloads.help"))
                Button(text("storage.nativeTrash")) {
                    if !StorageNativeTools.openTrash() { toolNotice = text("storage.toolFailed") }
                }.help(text("storage.nativeTrash.help"))
                Spacer()
                Text(text("storage.nativeNote")).font(.caption).foregroundStyle(.secondary)
            }
            if let toolNotice { Text(toolNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private var managementSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("storage.manageCache")).font(.title2.bold())
            Text(text("storage.manage.body")).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Button(text("storage.forget")) {
                            model.informationSheet = nil
                            Task { await model.removeSelectedGrant() }
                        }.disabled(model.selectedGrant == nil || model.isMutating)
                            .help(text("storage.forget.help"))
                        Text(text("storage.forget.body")).font(.callout).foregroundStyle(.secondary)
                        if let grant = model.selectedGrant {
                            Text(model.locationName(grant)).font(.caption).textSelection(.enabled)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Button(text("storage.clearCache")) { confirmsCacheClear = true }
                            .disabled(model.isMutating).help(text("storage.clearCache.help"))
                        Text(text("storage.clearCache.body")).font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Button(text("storage.resetLocations")) { confirmsLocationReset = true }
                            .disabled(model.isMutating).help(text("storage.resetLocations.help"))
                        Text(text("storage.resetLocations.body")).font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); informationCloseButton }
        }.padding(20).frame(width: 620, height: 440)
            .accessibilityIdentifier("storage-management-sheet")
            .confirmationDialog(text("storage.clearCache.title"), isPresented: $confirmsCacheClear, titleVisibility: .visible) {
                Button(text("storage.clearCache"), role: .destructive) {
                    model.informationSheet = nil
                    Task { await model.clearCache() }
                }.help(text("storage.clearCache.help"))
                Button(text("common.cancel"), role: .cancel) {}.help(text("common.cancel.help"))
            } message: { Text(text("storage.clearCache.body")) }
            .confirmationDialog(text("storage.resetLocations.title"), isPresented: $confirmsLocationReset, titleVisibility: .visible) {
                Button(text("storage.resetLocations"), role: .destructive) {
                    model.informationSheet = nil
                    Task { await model.resetSavedLocations() }
                }.help(text("storage.resetLocations.help"))
                Button(text("common.cancel"), role: .cancel) {}.help(text("common.cancel.help"))
            } message: { Text(text("storage.resetLocations.body")) }
    }

    private var accessSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("storage.access.title")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text("storage.access.body"))
                    Text(text("storage.access.steps")).textSelection(.enabled)
                    Text(StorageNativeTools.applicationURL.path).font(.caption).textSelection(.enabled)
                    #if APP_STORE
                    Text(text("storage.access.sandbox")).foregroundStyle(.secondary)
                    #endif
                    Text(text("storage.access.limitations")).foregroundStyle(.secondary)
                    if let toolNotice { Text(toolNotice).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(text("storage.access.openSettings")) {
                    model.cancelScan()
                    if !StorageNativeTools.openFullDiskAccessSettings() {
                        toolNotice = text("storage.access.settingsFallback")
                    }
                }.help(text("storage.access.openSettings.help"))
                Button(text("storage.access.copyPath")) {
                    NSPasteboard.general.clearContents()
                    _ = NSPasteboard.general.setString(StorageNativeTools.applicationURL.path, forType: .string)
                }.help(text("storage.access.copyPath.help"))
                Spacer()
                informationCloseButton
            }
            Button(text("storage.access.retry")) {
                model.informationSheet = nil
                model.refresh()
            }.disabled(model.selectedGrant == nil || model.isMutating || model.isLoading)
                .help(text("storage.access.retry.help"))
        }.padding(20).frame(width: 620, height: 440)
            .accessibilityIdentifier("storage-access-sheet")
    }

    private var informationCloseButton: some View {
        Button(text("storage.close")) { model.informationSheet = nil }
            .keyboardShortcut(.cancelAction).help(text("storage.information.close.help"))
    }

    private var issuesSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("storage.issues.title")).font(.title2.bold())
            Text(text("storage.issues.body")).foregroundStyle(.secondary)
            List(model.snapshot?.issues ?? [], id: \.self) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.path.isEmpty ? model.snapshot?.rootPath ?? "" : issue.path).textSelection(.enabled)
                    Text(text("storage.issue.\(issue.reason.rawValue)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(issue.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let count = model.snapshot?.omittedIssueCount, count > 0 {
                Text(text.format("storage.issues.omitted", count)).font(.caption)
            }
            Button(text("storage.close")) { showsIssues = false }.keyboardShortcut(.cancelAction).help(text("storage.close.help"))
        }.padding(20).frame(width: 620, height: 440)
    }

    private func trashConfirmation(_ pending: StorageTrashSelection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("storage.trash.title")).font(.title2.bold())
            Text(text.format("storage.selected", pending.nodeIDs.count)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(pending.paths.enumerated()), id: \.offset) { _, path in
                        Text(path).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Divider()
                    }
                }
            }
            Text(text.format("storage.trash.message", "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(text("common.cancel"), role: .cancel) { model.cancelTrashConfirmation() }
                    .keyboardShortcut(.cancelAction).help(text("common.cancel.help"))
                Button(text("storage.trash"), role: .destructive) {
                    model.cancelTrashConfirmation()
                    Task { await model.trashConfirmed(snapshotID: pending.snapshotID, nodeIDs: pending.nodeIDs) }
                }.help(text("storage.trash.help"))
            }
        }.padding(20).frame(width: 620, height: 440)
    }
}

struct StorageMapView: View {
    let nodes: [StorageItemReference]
    let metric: StorageSizeMetric
    let selection: Set<Int>
    let text: AppText
    var omittedBytes: UInt64 = 0
    let onSelect: (Int) -> Void
    let onOpen: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let positive = nodes.filter { $0.bytes(for: metric) > 0 }
            let shown = Array(positive.prefix(255))
            let rest = positive.dropFirst(255).reduce(omittedBytes) { $0 + $1.bytes(for: metric) }
            let items = shown.map { StorageMapItem(id: $0.id, bytes: $0.bytes(for: metric)) }
                + (rest > 0 ? [StorageMapItem(id: -1, bytes: rest)] : [])
            let tiles = StorageAreaMap.layout(items: items, width: geometry.size.width, height: geometry.size.height)
            ZStack(alignment: .topLeading) {
                Color.clear
                if tiles.isEmpty {
                    ContentUnavailableView(text("storage.mapEmpty"), systemImage: "square.dashed")
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                ForEach(tiles, id: \.id) { tile in
                    let node = shown.first { $0.id == tile.id }
                    let title = node?.name ?? text("storage.otherItems")
                    Button {
                        if let node { onSelect(node.id) }
                    } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(node).opacity(selection.contains(tile.id) ? 0.95 : 0.68))
                                .brightness(-0.22)
                            if tile.width > 68, tile.height > 35 {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                                    if tile.height > 56 {
                                        Text(StorageFormatting.bytes(node?.bytes(for: metric) ?? rest, text: text))
                                            .font(.caption2).lineLimit(1)
                                    }
                                }.padding(7).foregroundStyle(.white)
                            }
                            if selection.contains(tile.id) {
                                RoundedRectangle(cornerRadius: 3).stroke(.primary, lineWidth: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain).disabled(node == nil)
                    .frame(width: max(0, tile.width - 2), height: max(0, tile.height - 2))
                    .position(x: tile.x + tile.width / 2, y: tile.y + tile.height / 2)
                    .help("\(title) · \(StorageFormatting.bytes(node?.bytes(for: metric) ?? rest, text: text))\n\(text("storage.map.help"))")
                    .accessibilityLabel(title)
                    .accessibilityValue(StorageFormatting.bytes(node?.bytes(for: metric) ?? rest, text: text))
                    .onTapGesture(count: 2) { if let node { onOpen(node.id) } }
                }
            }
        }
        .accessibilityIdentifier("storage-area-map")
    }

    private func color(_ node: StorageItemReference?) -> Color {
        guard let node else { return .gray }
        if node.kind == .directory { return .blue }
        if node.kind == .package { return .purple }
        let palette: [Color] = [.teal, .indigo, .orange, .green, .pink]
        let key = node.name.split(separator: ".").last ?? Substring(node.name)
        let sum = key.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[sum]
    }
}

enum StorageFormatting {
    static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func bytes(_ bytes: UInt64, text: AppText) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes); var unit = 0
        while value >= 1_000, unit < units.count - 1 { value /= 1_000; unit += 1 }
        return value.formatted(.number.locale(Locale(identifier: text.language.resourceCode))
            .precision(.fractionLength(unit == 0 ? 0 : 1))) + " " + units[unit]
    }
    static func symbol(_ kind: StorageNodeKind) -> String {
        switch kind {
        case .directory: "folder"
        case .file: "doc"
        case .package: "shippingbox"
        case .symbolicLink: "link"
        case .other: "questionmark.square"
        }
    }
}
