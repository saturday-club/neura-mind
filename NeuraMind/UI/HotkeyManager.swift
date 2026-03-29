import Foundation
import Carbon
import AppKit

/// Manages global keyboard shortcuts using the Carbon RegisterEventHotKey API.
/// This is the most reliable approach for global hotkeys on macOS, used by
/// major apps like Raycast and Alfred.
final class HotkeyManager {
    private let logger = DualLogger(category: "Hotkey")

    /// Callback invoked when the primary global hotkey is pressed (Cmd+Shift+Space).
    var onHotkey: (() -> Void)?

    /// Callback invoked when the secondary global hotkey is pressed (Cmd+Shift+N).
    var onSecondaryHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var secondHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// The hotkey signature identifier (ASCII for "CTXD").
    private let signature: OSType = 0x43_54_58_44

    /// Shared instance (Carbon callbacks need a stable reference).
    static let shared = HotkeyManager()

    private init() {}

    deinit {
        unregister()
        unregisterSecondary()
    }

    /// Register a global hotkey.
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g., 49 for Space).
    ///   - modifiers: Carbon modifier flags (e.g., cmdKey | shiftKey).
    func register(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        unregister() // Remove any previous registration

        // Install the event handler for hot key events
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )

        guard status == noErr else {
            logger.error("Failed to install event handler: \(status)")
            return
        }

        // Register the hotkey
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            logger.info("Global hotkey registered (keyCode: \(keyCode), modifiers: \(modifiers))")
        } else {
            logger.error("Failed to register hotkey: \(registerStatus)")
        }
    }

    /// Register the secondary hotkey (default: Cmd+Shift+N, keyCode 45).
    /// Must be called after `register()` so the event handler is already installed.
    func registerSecondary(keyCode: UInt32 = 45, modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        unregisterSecondary()
        let hotKeyID = EventHotKeyID(signature: signature, id: 2)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &secondHotKeyRef
        )
        if status == noErr {
            logger.info("Secondary hotkey registered (keyCode: \(keyCode), modifiers: \(modifiers))")
        } else {
            logger.error("Failed to register secondary hotkey: \(status)")
        }
    }

    /// Unregister the current global hotkeys.
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    func unregisterSecondary() {
        if let ref = secondHotKeyRef {
            UnregisterEventHotKey(ref)
            secondHotKeyRef = nil
        }
    }

    /// Called by the Carbon event handler when any registered hotkey is pressed.
    fileprivate func handleHotKeyEvent(id: UInt32) {
        logger.debug("Hotkey pressed (id: \(id))")
        DispatchQueue.main.async { [weak self] in
            if id == 2 { self?.onSecondaryHotkey?() }
            else       { self?.onHotkey?() }
        }
    }
}

/// Carbon event handler callback (C function pointer).
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData, let event = event else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

    // Read the hotkey ID from the event to dispatch to the right callback.
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    manager.handleHotKeyEvent(id: hotKeyID.id)
    return noErr
}
