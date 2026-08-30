import Carbon.HIToolbox
import Foundation
import MacUtilsCore

struct HotKeyRegistrationToken: Hashable, Sendable {
    let rawValue: UInt32
}

protocol GlobalHotKeyRegistering: Sendable {
    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @Sendable () async -> Void
    ) async throws -> HotKeyRegistrationToken
    func unregister(_ token: HotKeyRegistrationToken) async
}

public enum GlobalHotKeyError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable(GlobalShortcut, status: Int32)

    public var description: String {
        switch self {
        case let .unavailable(shortcut, status):
            "Global shortcut keyCode=\(shortcut.keyCode), modifiers=\(shortcut.modifiers.rawValue) "
                + "is unavailable (OSStatus \(status))."
        }
    }
}

@MainActor
final class CarbonHotKeyRegistrar: GlobalHotKeyRegistering {
    private struct Registration {
        let reference: EventHotKeyRef
        let handler: @Sendable () async -> Void
    }

    private static let signature: OSType = 0x4D_63_55_74 // "McUt"
    private var nextID: UInt32 = 1
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private let diagnostics: Bool

    init(diagnostics: Bool = false) throws {
        self.diagnostics = diagnostics
        guard let dispatcher = GetEventDispatcherTarget() else {
            throw GlobalHotKeyError.unavailable(
                GlobalShortcut(keyCode: 0, modifiers: []),
                status: OSStatus(eventNotHandledErr)
            )
        }
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            dispatcher,
            macUtilsCarbonHotKeyHandler,
            0,
            nil,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr, let eventHandler else {
            throw GlobalHotKeyError.unavailable(
                GlobalShortcut(keyCode: 0, modifiers: []),
                status: status
            )
        }
        let eventTypeStatus = AddEventTypesToHandler(eventHandler, 1, &specification)
        guard eventTypeStatus == noErr else {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
            throw GlobalHotKeyError.unavailable(
                GlobalShortcut(keyCode: 0, modifiers: []),
                status: eventTypeStatus
            )
        }
    }

    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @Sendable () async -> Void
    ) async throws -> HotKeyRegistrationToken {
        let id = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: id)
        guard let dispatcher = GetEventDispatcherTarget() else {
            throw GlobalHotKeyError.unavailable(shortcut, status: OSStatus(eventNotHandledErr))
        }
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(shortcut.modifiers),
            identifier,
            dispatcher,
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw GlobalHotKeyError.unavailable(shortcut, status: status)
        }
        registrations[id] = Registration(reference: reference, handler: handler)
        return HotKeyRegistrationToken(rawValue: id)
    }

    func unregister(_ token: HotKeyRegistrationToken) async {
        guard let registration = registrations.removeValue(forKey: token.rawValue) else { return }
        UnregisterEventHotKey(registration.reference)
    }

    private func dispatch(id: UInt32) {
        guard let handler = registrations[id]?.handler else { return }
        Task { await handler() }
    }

    fileprivate func handle(event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        report(identifier: identifier, parameterStatus: status)
        guard status == noErr, identifier.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }
        dispatch(id: identifier.id)
        return noErr
    }

    private func report(identifier: EventHotKeyID, parameterStatus: OSStatus) {
        guard diagnostics else { return }
        print(
            "carbonHotKeyEvent=true id=\(identifier.id) signature=\(identifier.signature) "
                + "parameterStatus=\(parameterStatus)"
        )
    }

    private func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

nonisolated private func macUtilsCarbonHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData, Thread.isMainThread else {
        return OSStatus(eventNotHandledErr)
    }
    let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    let eventAddress = UInt(bitPattern: event)
    return MainActor.assumeIsolated {
        guard let isolatedEvent = EventRef(bitPattern: eventAddress) else {
            return OSStatus(eventNotHandledErr)
        }
        return registrar.handle(event: isolatedEvent)
    }
}
