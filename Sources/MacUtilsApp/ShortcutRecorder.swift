import AppKit
import MacUtilsCore
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut?
    let text: AppText

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut)
    }

    func makeNSView(context: Context) -> ShortcutCaptureButton {
        let button = ShortcutCaptureButton()
        button.bezelStyle = .rounded
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecording(_:))
        button.onShortcut = { shortcut in
            context.coordinator.shortcut.wrappedValue = shortcut
        }
        button.text = text
        return button
    }

    func updateNSView(_ button: ShortcutCaptureButton, context: Context) {
        button.displayedShortcut = shortcut
        button.text = text
    }

    @MainActor
    final class Coordinator: NSObject {
        let shortcut: Binding<GlobalShortcut?>

        init(shortcut: Binding<GlobalShortcut?>) {
            self.shortcut = shortcut
        }

        @objc func beginRecording(_ sender: ShortcutCaptureButton) {
            sender.beginRecording()
        }
    }
}

@MainActor
final class ShortcutCaptureButton: NSButton {
    var text = AppText(language: .system) {
        didSet { updatePresentation() }
    }
    var onShortcut: ((GlobalShortcut) -> Void)?
    var displayedShortcut: GlobalShortcut? {
        didSet {
            guard !isRecording else { return }
            updatePresentation()
        }
    }
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    func beginRecording() {
        isRecording = true
        title = text("recorder.press")
        setAccessibilityValue(text("recorder.press"))
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control) else {
            NSSound.beep()
            title = text("recorder.modifierRequired")
            setAccessibilityValue(text("recorder.modifierRequired"))
            return
        }

        let shortcut = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        isRecording = false
        displayedShortcut = shortcut
        onShortcut?(shortcut)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if isRecording { cancelRecording() }
        return result
    }

    private func cancelRecording() {
        isRecording = false
        updatePresentation()
        window?.makeFirstResponder(nil)
    }

    private func updatePresentation() {
        guard !isRecording else { return }
        title = displayedShortcut.map(text.shortcut) ?? text("recorder.record")
        setAccessibilityValue(displayedShortcut.map(text.shortcut) ?? text("recorder.record"))
        toolTip = text("recorder.help")
        setAccessibilityLabel(text("recorder.accessibility"))
        setAccessibilityHelp(text("recorder.help"))
        setAccessibilityIdentifier("shortcut-recorder")
    }
}
