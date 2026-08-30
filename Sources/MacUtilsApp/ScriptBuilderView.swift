import MacUtilsCore
import SwiftUI

struct ScriptBuilderView: View {
    @Binding var builder: ScenarioBuilder
    @ObservedObject var model: AppModel

    var body: some View {
        ScenarioBranchView(
            builder: $builder,
            model: model,
            location: .root,
            depth: 0,
            title: nil
        )
    }
}

private struct ScenarioBranchView: View {
    @Binding var builder: ScenarioBuilder
    @ObservedObject var model: AppModel
    let location: ScenarioBuilderLocation
    let depth: Int
    let title: String?

    private var branchSnapshot: (steps: [ScenarioBuilderStep], error: String?) {
        do {
            return (try builder.steps(in: location), nil)
        } catch {
            return ([], model.text.error(error))
        }
    }
    private var text: AppText { model.text }

    var body: some View {
        let snapshot = branchSnapshot
        let steps = snapshot.steps
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let title {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                addMenu
                Spacer()
                Text(steps.count == 1 ? text("builder.stepCount.one") : text.format("builder.stepCount.many", steps.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if steps.isEmpty {
                Text(text(depth == 0 ? "builder.empty.root" : "builder.empty.branch"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: depth == 0 ? 110 : 44)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepView(step, index: index, count: steps.count)
                            .draggable(step.id.uuidString)
                            .dropDestination(for: String.self) { identifiers, _ in
                                guard let rawID = identifiers.first,
                                      let id = UUID(uuidString: rawID),
                                      steps.contains(where: { $0.id == id }) else { return false }
                                do {
                                    try builder.move(stepID: id, to: index, in: location)
                                    return true
                                } catch {
                                    model.reportEditorError(error)
                                    return false
                                }
                            }
                    }
                }
            }

            if depth == 0 {
                DisclosureGroup(text("builder.dslPreview")) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(builder.canonicalDSL().isEmpty ? text("builder.dslEmpty") : builder.canonicalDSL())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 150)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Section(text("builder.actions")) {
                ForEach(builder.actionCatalog.sorted(by: { $0.name < $1.name }), id: \.id) { action in
                    Button(text.actionName(action)) {
                        do { try builder.addAction(action.id, to: location) }
                        catch { model.reportEditorError(error) }
                    }
                }
            }
            Section(text("builder.toggleByState")) {
                ForEach(builder.stateProviderCatalog.sorted(by: { $0.name < $1.name }), id: \.id) { provider in
                    Button(text.providerName(provider)) {
                        do { try builder.addToggle(provider.id, to: location) }
                        catch { model.reportEditorError(error) }
                    }
                }
            }
        } label: {
            Label(text("builder.addStep"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(text("builder.addStep.help"))
    }

    @ViewBuilder
    private func stepView(_ step: ScenarioBuilderStep, index: Int, count: Int) -> some View {
        switch step {
        case let .action(action):
            ActionStepCard(
                builder: $builder,
                model: model,
                step: action,
                location: location,
                index: index,
                count: count
            )
        case let .toggle(toggle):
            ToggleStepCard(
                builder: $builder,
                model: model,
                step: toggle,
                location: location,
                index: index,
                count: count,
                depth: depth
            )
        }
    }
}

private struct ActionStepCard: View {
    @Binding var builder: ScenarioBuilder
    @ObservedObject var model: AppModel
    let step: ActionBuilderStep
    let location: ScenarioBuilderLocation
    let index: Int
    let count: Int

    private var metadata: ActionMetadata? { builder.actionMetadata(for: step.actionID) }
    private var text: AppText { model.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(
                number: index + 1,
                title: metadata.map(text.actionName) ?? step.actionID.rawValue,
                subtitle: metadata.map(text.actionDescription),
                text: text,
                canMoveUp: index > 0,
                canMoveDown: index + 1 < count,
                moveUp: { move(to: index - 1) },
                moveDown: { move(to: index + 1) },
                duplicate: duplicate,
                remove: remove
            )
            ParameterGrid {
                ForEach(metadata?.parameters ?? [], id: \.name) { parameter in
                    ParameterEditor(
                        parameter: parameter,
                        value: step.parameters[parameter.name],
                        displays: displayChoices(for: parameter),
                        ownerID: step.actionID.rawValue,
                        text: text,
                        onChange: { set(parameter, value: $0) }
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.65)))
    }

    private func displayChoices(for parameter: ActionParameter) -> [DisplayDescriptor] {
        guard parameter.name == "source",
              case let .string(target)? = step.parameters["display"] else { return model.displays }
        return model.displays.filter { $0.id.rawValue != target }
    }

    private func set(_ parameter: ActionParameter, value: ActionValue?) {
        do { try builder.setActionParameter(stepID: step.id, name: parameter.name, value: value) }
        catch { model.reportEditorError(error) }
    }

    private func move(to destination: Int) {
        do { try builder.move(stepID: step.id, to: destination, in: location) }
        catch { model.reportEditorError(error) }
    }

    private func duplicate() {
        do { try builder.duplicate(stepID: step.id, in: location) }
        catch { model.reportEditorError(error) }
    }

    private func remove() {
        do { try builder.remove(stepID: step.id, from: location) }
        catch { model.reportEditorError(error) }
    }
}

private struct ToggleStepCard: View {
    @Binding var builder: ScenarioBuilder
    @ObservedObject var model: AppModel
    let step: ToggleBuilderStep
    let location: ScenarioBuilderLocation
    let index: Int
    let count: Int
    let depth: Int

    private var metadata: StateProviderMetadata? { builder.providerMetadata(for: step.providerID) }
    private var text: AppText { model.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                number: index + 1,
                title: text.format("builder.toggleTitle", metadata.map(text.providerName) ?? step.providerID.rawValue),
                subtitle: metadata.map(text.providerDescription),
                text: text,
                canMoveUp: index > 0,
                canMoveDown: index + 1 < count,
                moveUp: { move(to: index - 1) },
                moveDown: { move(to: index + 1) },
                duplicate: duplicate,
                remove: remove
            )

            ParameterGrid {
                ForEach(metadata?.parameters ?? [], id: \.name) { parameter in
                    ParameterEditor(
                        parameter: parameter,
                        value: step.parameters[parameter.name],
                        displays: model.displays,
                        ownerID: step.providerID.rawValue,
                        text: text,
                        onChange: { set(parameter, value: $0) }
                    )
                }
                if let options = metadata?.options, !options.isEmpty {
                    GridRow {
                        Text(text("builder.whenState")).foregroundStyle(.secondary).frame(width: 112, alignment: .trailing)
                        Picker("", selection: expectedBinding) {
                            ForEach(options, id: \.value) { option in
                                Text(text.optionLabel(providerID: step.providerID, option: option)).tag(option.value)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            AnyView(ScenarioBranchView(
                builder: $builder,
                model: model,
                location: .matching(toggleID: step.id),
                depth: depth + 1,
                title: text("builder.then")
            ))
            .padding(12)
            .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))

            AnyView(ScenarioBranchView(
                builder: $builder,
                model: model,
                location: .otherwise(toggleID: step.id),
                depth: depth + 1,
                title: text("builder.otherwise")
            ))
            .padding(12)
            .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.purple.opacity(0.35), lineWidth: 1.5))
    }

    private var expectedBinding: Binding<ActionValue> {
        Binding(
            get: { step.expectedValue },
            set: { value in
                do { try builder.setExpectedValue(stepID: step.id, value: value) }
                catch { model.reportEditorError(error) }
            }
        )
    }

    private func set(_ parameter: ActionParameter, value: ActionValue?) {
        do { try builder.setToggleParameter(stepID: step.id, name: parameter.name, value: value) }
        catch { model.reportEditorError(error) }
    }

    private func move(to destination: Int) {
        do { try builder.move(stepID: step.id, to: destination, in: location) }
        catch { model.reportEditorError(error) }
    }

    private func duplicate() {
        do { try builder.duplicate(stepID: step.id, in: location) }
        catch { model.reportEditorError(error) }
    }

    private func remove() {
        do { try builder.remove(stepID: step.id, from: location) }
        catch { model.reportEditorError(error) }
    }
}

private struct StepHeader: View {
    let number: Int
    let title: String
    let subtitle: String?
    let text: AppText
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void
    @State private var confirmsDeletion = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Button(action: moveUp) { Image(systemName: "arrow.up") }
                    .disabled(!canMoveUp).help(text("builder.moveUp")).accessibilityLabel(text("builder.moveUp"))
                Button(action: moveDown) { Image(systemName: "arrow.down") }
                    .disabled(!canMoveDown).help(text("builder.moveDown")).accessibilityLabel(text("builder.moveDown"))
                Button(action: duplicate) { Image(systemName: "plus.square.on.square") }
                    .help(text("builder.duplicate")).accessibilityLabel(text("builder.duplicate"))
                Button(role: .destructive) { confirmsDeletion = true } label: { Image(systemName: "trash") }
                    .help(text("builder.delete")).accessibilityLabel(text("builder.delete"))
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .confirmationDialog(text("builder.delete.title"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(text("common.delete"), role: .destructive, action: remove)
            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("builder.delete.message"))
        }
    }
}

private struct ParameterGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ParameterEditor: View {
    let parameter: ActionParameter
    let value: ActionValue?
    let displays: [DisplayDescriptor]
    let ownerID: String
    let text: AppText
    let onChange: (ActionValue?) -> Void

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            editor
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(text.parameterHelp(ownerID: ownerID, parameter: parameter))
    }

    @ViewBuilder
    private var editor: some View {
        if parameter.type == .string, parameter.name == "display" || parameter.name == "source" {
            Picker("", selection: optionalStringBinding) {
                Text(text("builder.chooseDisplay")).tag(Optional<String>.none)
                ForEach(displays, id: \.id) { display in
                    Text("\(display.name) — \(text.role(display.role))")
                        .tag(Optional(display.id.rawValue))
                }
            }
            .labelsHidden()
        } else {
            switch parameter.type {
            case .string:
                TextField(text.parameterHelp(ownerID: ownerID, parameter: parameter), text: stringBinding)
            case .integer:
                TextField(text.parameterHelp(ownerID: ownerID, parameter: parameter), value: integerBinding, format: .number).frame(width: 140)
            case .number:
                TextField(text.parameterHelp(ownerID: ownerID, parameter: parameter), value: numberBinding, format: .number).frame(width: 140)
            case .boolean:
                Toggle(text.parameterHelp(ownerID: ownerID, parameter: parameter), isOn: booleanBinding).labelsHidden()
            }
        }
    }

    private var label: String {
        text.parameterLabel(ownerID: ownerID, parameter: parameter)
    }

    private var optionalStringBinding: Binding<String?> {
        Binding(
            get: { if case let .string(value) = self.value { value } else { nil } },
            set: { onChange($0.map(ActionValue.string)) }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { if case let .string(value) = self.value { value } else { "" } },
            set: { onChange(.string($0)) }
        )
    }

    private var integerBinding: Binding<Int> {
        Binding(
            get: { if case let .integer(value) = self.value { value } else { 0 } },
            set: { onChange(.integer($0)) }
        )
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: { if case let .number(value) = self.value { value } else { 0 } },
            set: { onChange(.number($0)) }
        )
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: { if case let .boolean(value) = self.value { value } else { false } },
            set: { onChange(.boolean($0)) }
        )
    }
}
