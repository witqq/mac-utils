import AppKit
import MacUtilsCore
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var model: AppModel
    let onOpenSettings: () -> Void
    private var text: AppText { model.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("menu.displays"))
                    .font(.headline)
                Spacer()
                if model.isRefreshingDisplays {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refreshDisplays() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(text("menu.refresh"))
                .accessibilityLabel(text("menu.refresh"))
            }

            if model.isStarting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text("status.loading"))
                }
                .foregroundStyle(.secondary)
            } else if model.displays.isEmpty {
                Text(text("menu.noDisplays"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.displays, id: \.id) { display in
                    displayRow(display)
                }
            }

            messageArea
            Divider()
            HStack {
                Button(text("menu.settings"), action: onOpenSettings)
                    .help(text("menu.settings"))
                Spacer()
                Button(text("menu.quit")) { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 390)
    }

    @ViewBuilder
    private func displayRow(_ display: DisplayDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name).fontWeight(.medium)
                    Text("\(text.role(display.role)) · \(display.frame.width)×\(display.frame.height)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !display.isActive {
                    Text(text("menu.inactive")).font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                Button(text("menu.main")) {
                    Task { await model.makeMain(display.id) }
                }
                .disabled(display.role == .main)
                .help(text("menu.main.help"))

                Button(text("menu.extend")) {
                    Task { await model.extend(display.id) }
                }
                .disabled(display.role == .extended || display.role == .main)
                .help(text("menu.extend.help"))

                Menu(text("menu.mirror")) {
                    ForEach(model.displays.filter { $0.id != display.id }, id: \.id) { source in
                        Button(source.name) {
                            Task { await model.mirror(display.id, source: source.id) }
                        }
                    }
                }
                .disabled(model.displays.count < 2)
                .help(text("menu.mirror.help"))
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var messageArea: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).font(.caption).textSelection(.enabled)
                Spacer()
                Button { model.dismissMessages() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(text("message.dismiss"))
                    .accessibilityLabel(text("message.dismiss"))
            }
        } else if let notice = model.noticeMessage {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(notice).font(.caption)
                Spacer()
                Button { model.dismissMessages() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(text("message.dismiss"))
                    .accessibilityLabel(text("message.dismiss"))
            }
        }
    }
}
