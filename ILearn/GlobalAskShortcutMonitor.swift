//
//  GlobalAskShortcutMonitor.swift
//  ILearn
//
//  Captures the global "ask ILearn" keyboard shortcut (Control+X) while the
//  app is running in the background. Uses a listen-only CGEvent tap so the
//  shortcut works system-wide even when another app is focused.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// The single hardcoded shortcut that opens the Ask Window. Control+X is used
/// here; note the tap is listen-only, so it never swallows the keystroke —
/// Control+X still works normally elsewhere (and macOS cut is Command+X, not
/// Control+X, so there's no cut conflict).
enum AskShortcut {
    enum Transition {
        case none
        case pressed
        case released
    }

    static let displayText = "control + x"

    /// Virtual keycode for the "X" key (kVK_ANSI_X).
    private static let askKeyCode: UInt16 = 7
    private static let requiredModifierFlags: NSEvent.ModifierFlags = [.control]

    static func transition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> Transition {
        guard keyCode == askKeyCode else { return .none }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let matchesModifierFlags = modifierFlags == requiredModifierFlags

        if eventType == .keyDown && matchesModifierFlags && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if eventType == .keyUp && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

final class GlobalAskShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<AskShortcut.Transition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalAskShortcutMonitor = Unmanaged<GlobalAskShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalAskShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global ask shortcut: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global ask shortcut: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = AskShortcut.transition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
