import AppKit
import Foundation
import MacUtilsCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = SettingsTab.scripts
    @State private var showsOnboarding: Bool
    private let persistsOnboarding: Bool

    init(
        model: AppModel,
        onboardingOverride: Bool? = nil,
        initialTab: SettingsTab = .scripts
    ) {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
        persistsOnboarding = onboardingOverride == nil
        _showsOnboarding = State(initialValue: onboardingOverride
            ?? !UserDefaults.standard.bool(forKey: "completedOnboarding"))
    }

    private var text: AppText { model.text }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("", selection: $selectedTab) {
                    Label(text("tab.general"), systemImage: "gearshape").tag(SettingsTab.general)
                    Label(text("tab.scripts"), systemImage: "square.stack.3d.up").tag(SettingsTab.scripts)
                    Label(text("tab.shortcuts"), systemImage: "command").tag(SettingsTab.shortcuts)
                    Label(text("tab.help"), systemImage: "questionmark.circle").tag(SettingsTab.help)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 560)
                .accessibilityIdentifier("settings-navigation")
                Spacer()
                Picker(text("language.picker"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(text.languageName(language)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                .help(text("language.help"))
                .accessibilityIdentifier("language-picker")
            }

            Group {
                switch selectedTab {
                case .general:
                GeneralSettingsView(model: model)
                case .scripts:
                ScriptSettingsView(model: model)
                case .shortcuts:
                ShortcutSettingsView(model: model)
                case .help:
                HelpView(text: text)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 960, minHeight: 680)
        .environment(\.locale, Locale(identifier: model.language.resourceCode))
        .background(WindowTitleSetter(title: text("app.settings.title")))
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(
                text: text,
                onContinue: completeOnboarding,
                onOpenHelp: {
                    completeOnboarding()
                    selectedTab = .help
                }
            )
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { model.language }, set: { model.setLanguage($0) })
    }

    private func completeOnboarding() {
        if persistsOnboarding { UserDefaults.standard.set(true, forKey: "completedOnboarding") }
        showsOnboarding = false
    }
}

enum SettingsTab: String, Hashable {
    case general
    case scripts
    case shortcuts
    case help
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    private var text: AppText { model.text }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(text("general.title")).font(.largeTitle.bold())
                Text(text("general.description")).font(.title3).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    Toggle(text("general.loginItem.title"), isOn: loginItemBinding)
                        .toggleStyle(.switch)
                        .help(text("general.loginItem.help"))
                        .accessibilityIdentifier("launch-at-login-toggle")
                    Text(text("general.loginItem.description"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(statusText, systemImage: statusSymbol)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("launch-at-login-status")

                    if model.loginItemStatus == .requiresApproval {
                        Text(text("general.loginItem.approval"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button(text("general.loginItem.openSettings")) {
                            model.openLoginItemsSettings()
                        }
                        .help(text("general.loginItem.openSettings.help"))
                        .accessibilityIdentifier("open-login-items-settings")
                        Button(text("general.loginItem.refresh")) {
                            model.refreshLoginItemStatus()
                        }
                        .help(text("general.loginItem.refresh.help"))
                    }
                }
                .padding(20)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))

                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else if let notice = model.noticeMessage {
                    Text(notice).font(.caption).foregroundStyle(.green)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(30)
        }
        .accessibilityIdentifier("general-settings")
        .onAppear { model.refreshLoginItemStatus() }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: {
                model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval
            },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }

    private var statusText: String {
        switch model.loginItemStatus {
        case .notRegistered: text("general.loginItem.status.disabled")
        case .enabled: text("general.loginItem.status.enabled")
        case .requiresApproval: text("general.loginItem.status.requiresApproval")
        case .notFound: text("general.loginItem.status.notFound")
        }
    }

    private var statusSymbol: String {
        switch model.loginItemStatus {
        case .notRegistered: "circle"
        case .enabled: "checkmark.circle.fill"
        case .requiresApproval: "exclamationmark.triangle.fill"
        case .notFound: "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.loginItemStatus {
        case .notRegistered: .secondary
        case .enabled: .green
        case .requiresApproval: .orange
        case .notFound: .red
        }
    }
}

private enum ScriptEditorMode: CaseIterable, Identifiable {
    case visual
    case text
    var id: Self { self }

    func label(_ text: AppText) -> String {
        switch self {
        case .visual: text("scripts.editor.visual")
        case .text: text("scripts.editor.text")
        }
    }
}

private struct ScriptSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: UUID?
    @State private var draftName = ""
    @State private var draftSource = ""
    @State private var editorMode = ScriptEditorMode.visual
    @State private var builder: ScenarioBuilder
    @State private var editorError: String?
    @State private var pendingDeletion: UUID?

    init(model: AppModel) {
        self.model = model
        _builder = State(initialValue: model.makeScenarioBuilder())
    }

    private var text: AppText { model.text }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text("scripts.title")).font(.headline).padding(.horizontal, 10)
                ZStack {
                    List(selection: $selectedID) {
                        ForEach(model.scripts) { script in
                            Text(script.name).tag(Optional(script.id))
                        }
                    }
                    .listStyle(.sidebar)
                    .accessibilityIdentifier("scripts-list")
                    if model.scripts.isEmpty, selectedID == nil {
                        ContentUnavailableView(
                            text("scripts.empty.title"),
                            systemImage: "square.stack.3d.up.slash",
                            description: Text(text("scripts.empty.description"))
                        )
                    }
                }
                HStack {
                    Button(action: newScript) { Image(systemName: "plus") }
                        .help(text("scripts.new"))
                        .accessibilityLabel(text("scripts.new"))
                        .accessibilityIdentifier("new-script")
                    Button { pendingDeletion = selectedID } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                        .help(text("scripts.delete"))
                        .accessibilityLabel(text("scripts.delete"))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(width: 218)
            .background(.quaternary.opacity(0.22))

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text(text("scripts.name")).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                        TextField(text("scripts.name.placeholder"), text: $draftName)
                            .accessibilityIdentifier("script-name")
                    }
                    HStack(spacing: 12) {
                        Text(text("scripts.editor")).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                        Picker(text("scripts.editor"), selection: $editorMode) {
                            ForEach(ScriptEditorMode.allCases) { mode in Text(mode.label(text)).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                        .labelsHidden()
                        .help(text("scripts.editor.help"))
                        .accessibilityIdentifier("editor-mode")
                        Spacer()
                    }
                }

                Group {
                    if editorMode == .visual {
                        ScriptBuilderView(builder: $builder, model: model)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $draftSource)
                                .font(.system(.body, design: .monospaced))
                                .border(.separator)
                                .accessibilityIdentifier("dsl-editor")
                            Text(text("scripts.dsl.help")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                HStack {
                    Button(text("scripts.validate")) { validateCurrentSource() }
                        .help(text("scripts.validate.help"))
                        .accessibilityLabel(text("scripts.validate"))
                    Button(text("scripts.save")) {
                        Task {
                            guard let source = sourceForSaving() else { return }
                            if let id = await model.saveScript(id: selectedID, name: draftName, source: source) {
                                selectedID = id
                                draftSource = source
                            }
                        }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .help(text("scripts.save.help"))
                    .accessibilityLabel(text("scripts.save"))
                    .accessibilityIdentifier("save-script")
                    Spacer()
                    inlineMessage
                }
                .frame(minHeight: 30)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: selectFirstScriptIfNeeded)
        .onChange(of: selectedID) { _, newValue in loadScript(id: newValue) }
        .onChange(of: model.scripts) { _, _ in selectFirstScriptIfNeeded() }
        .onChange(of: editorMode) { oldMode, newMode in switchMode(from: oldMode, to: newMode) }
        .confirmationDialog(
            text("scripts.delete.title"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(text("common.delete"), role: .destructive) {
                guard let id = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    await model.removeScript(id: id)
                    if !model.scripts.contains(where: { $0.id == id }) { newScript() }
                }
            }
            Button(text("common.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(text.format(
                "scripts.delete.message",
                pendingDeletion.map { model.bindingCount(for: $0) } ?? 0
            ))
        }
    }

    private func newScript() {
        selectedID = nil
        draftName = ""
        draftSource = ""
        builder = model.makeScenarioBuilder()
        editorMode = .visual
        editorError = nil
        model.dismissMessages()
    }

    private func selectFirstScriptIfNeeded() {
        guard selectedID == nil, draftName.isEmpty, let first = model.scripts.first else { return }
        selectedID = first.id
        loadScript(id: first.id)
    }

    private func loadScript(id: UUID?) {
        guard let id, let script = model.scripts.first(where: { $0.id == id }) else { return }
        var candidate = model.makeScenarioBuilder()
        do {
            try candidate.replace(withDSL: script.source, name: script.name)
            builder = candidate
            draftName = script.name
            draftSource = candidate.canonicalDSL(name: script.name)
            editorError = nil
        } catch {
            draftName = script.name
            draftSource = script.source
            editorMode = .text
            editorError = text.error(error)
        }
    }

    private func switchMode(from oldMode: ScriptEditorMode, to newMode: ScriptEditorMode) {
        guard oldMode != newMode else { return }
        switch newMode {
        case .text:
            draftSource = builder.canonicalDSL(name: draftName)
            editorError = nil
        case .visual:
            var candidate = builder
            do {
                try candidate.replace(withDSL: draftSource, name: draftName)
                builder = candidate
                draftSource = candidate.canonicalDSL(name: draftName)
                editorError = nil
            } catch {
                editorError = text.error(error)
                editorMode = .text
            }
        }
    }

    private func sourceForSaving() -> String? {
        if editorMode == .visual { return builder.canonicalDSL(name: draftName) }
        guard model.validateScript(name: draftName, source: draftSource) else { return nil }
        return draftSource
    }

    private func validateCurrentSource() {
        guard let source = sourceForSaving() else { return }
        _ = model.validateScript(name: draftName, source: source)
    }

    @ViewBuilder private var inlineMessage: some View {
        if let editorError { Text(editorError).font(.caption).foregroundStyle(.red).lineLimit(2) }
        else if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
        else if let notice = model.noticeMessage { Text(notice).font(.caption).foregroundStyle(.green) }
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedScriptID: UUID?
    @State private var recordedShortcut: GlobalShortcut?
    @State private var editingBindingID: UUID?
    @State private var pendingRemoval: UUID?

    private var text: AppText { model.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("shortcuts.title")).font(.title2).fontWeight(.semibold)
            Text(text("shortcuts.description")).foregroundStyle(.secondary)

            if model.scripts.isEmpty {
                ContentUnavailableView(
                    text("shortcuts.noScripts.title"),
                    systemImage: "command",
                    description: Text(text("shortcuts.noScripts.description"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Picker(text("shortcuts.script"), selection: $selectedScriptID) {
                        Text(text("shortcuts.chooseScript")).tag(Optional<UUID>.none)
                        ForEach(model.scripts) { script in Text(script.name).tag(Optional(script.id)) }
                    }
                    .frame(maxWidth: 320)
                    .help(text("shortcuts.script.help"))
                    .accessibilityIdentifier("shortcut-script-picker")
                    ShortcutRecorder(shortcut: $recordedShortcut, text: text).frame(width: 190)
                    Button(editingBindingID == nil ? text("shortcuts.assign") : text("shortcuts.saveChange")) {
                        saveBinding()
                    }
                    .disabled(selectedScriptID == nil || recordedShortcut == nil)
                    .help(text("shortcuts.assign.help"))
                    .accessibilityLabel(editingBindingID == nil
                        ? text("shortcuts.assign") : text("shortcuts.saveChange"))
                    .accessibilityIdentifier("save-shortcut")
                    if editingBindingID != nil {
                        Button(text("shortcuts.cancelEdit"), action: cancelEditing)
                            .accessibilityLabel(text("shortcuts.cancelEdit"))
                            .help(text("shortcuts.cancelEdit.help"))
                    }
                }

                ZStack {
                    List {
                        ForEach(model.bindings) { binding in
                            HStack {
                                Text(text.shortcut(binding.shortcut))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 120, alignment: .leading)
                                Text(model.scriptName(for: binding.scriptID))
                                Spacer()
                                Button(text("shortcuts.edit")) { beginEditing(binding) }
                                    .help(text("shortcuts.edit.help"))
                                    .accessibilityLabel(text("shortcuts.edit"))
                                    .accessibilityIdentifier("edit-shortcut")
                                Button(text("common.remove"), role: .destructive) { pendingRemoval = binding.id }
                                    .accessibilityLabel(text("common.remove"))
                                    .help(text("shortcuts.remove.help"))
                                    .accessibilityIdentifier("remove-shortcut")
                            }
                            .accessibilityIdentifier("shortcut-row-\(binding.id.uuidString)")
                        }
                    }
                    .accessibilityIdentifier("shortcuts-list")
                    if model.bindings.isEmpty {
                        ContentUnavailableView(
                            text("shortcuts.empty.title"),
                            systemImage: "command",
                            description: Text(text("shortcuts.empty.description"))
                        )
                    }
                }
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("shortcut-error")
            } else if let notice = model.noticeMessage {
                Text(notice).font(.caption).foregroundStyle(.green)
            }
        }
        .confirmationDialog(
            text("shortcuts.remove.title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(text("common.remove"), role: .destructive) {
                guard let id = pendingRemoval else { return }
                pendingRemoval = nil
                Task {
                    await model.removeBinding(id: id)
                    if editingBindingID == id { cancelEditing() }
                }
            }
            Button(text("common.cancel"), role: .cancel) { pendingRemoval = nil }
        } message: { Text(text("shortcuts.remove.message")) }
    }

    private func saveBinding() {
        guard let selectedScriptID, let recordedShortcut else { return }
        if let editingBindingID {
            Task {
                if await model.updateBinding(id: editingBindingID, shortcut: recordedShortcut, scriptID: selectedScriptID) {
                    cancelEditing()
                }
            }
        } else {
            Task {
                await model.assign(recordedShortcut, to: selectedScriptID)
                if model.errorMessage == nil { self.recordedShortcut = nil }
            }
        }
    }

    private func beginEditing(_ binding: ShortcutBinding) {
        editingBindingID = binding.id
        selectedScriptID = binding.scriptID
        recordedShortcut = binding.shortcut
        model.dismissMessages()
    }

    private func cancelEditing() {
        editingBindingID = nil
        selectedScriptID = nil
        recordedShortcut = nil
        model.dismissMessages()
    }
}

private struct HelpView: View {
    let text: AppText

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(text("help.title")).font(.largeTitle.bold())
                Text(text("help.intro")).font(.title3).foregroundStyle(.secondary)
                helpSection(text("help.quickStart"), rows: [
                    ("1.circle.fill", text("help.step1")),
                    ("2.circle.fill", text("help.step2")),
                    ("3.circle.fill", text("help.step3")),
                ])
                helpSection(text("help.toggle.title"), rows: [
                    ("arrow.triangle.2.circlepath", text("help.toggle.body")),
                ])
                helpSection(text("help.terms"), rows: [
                    ("menubar.rectangle", text("help.term.main")),
                    ("rectangle.split.2x1", text("help.term.extended")),
                    ("rectangle.on.rectangle", text("help.term.mirror")),
                    ("arrow.left.arrow.right", text("help.term.toggle")),
                ])
                helpSection(text("help.safety"), rows: [("lock.shield", text("help.safety.body"))])
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(30)
        }
        .accessibilityIdentifier("help-screen")
    }

    private func helpSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.0).frame(width: 24).foregroundStyle(.tint).accessibilityHidden(true)
                    Text(row.1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct OnboardingView: View {
    let text: AppText
    let onContinue: () -> Void
    let onOpenHelp: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(text("onboarding.title")).font(.largeTitle.bold())
                Text(text("onboarding.subtitle")).font(.title3).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                onboardingCard("square.stack.3d.up.fill", "onboarding.visual.title", "onboarding.visual.body")
                onboardingCard("command", "onboarding.hotkey.title", "onboarding.hotkey.body")
                onboardingCard("questionmark.circle.fill", "onboarding.learn.title", "onboarding.learn.body")
            }
            HStack {
                Button(text("onboarding.openHelp"), action: onOpenHelp)
                Button(text("onboarding.continue"), action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("finish-onboarding")
            }
        }
        .padding(30)
        .frame(width: 760, height: 430)
        .accessibilityIdentifier("onboarding")
    }

    private func onboardingCard(_ symbol: String, _ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
            Text(text(titleKey)).font(.headline)
            Text(text(bodyKey)).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in view.window?.title = title }
    }
}
