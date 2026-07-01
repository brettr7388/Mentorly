//
//  GlobalAskShortcutMonitor.swift
//  Mentorly
//
//  Captures the global "ask Mentorly" trigger — a double-tap of the Command
//  key — while the app is running in the background. Uses a listen-only
//  CGEvent tap so the trigger works system-wide even when another app is
//  focused. Double-tapping Command is one-handed (one thumb) and doesn't
//  collide with anything: a lone Command tap does nothing on its own, and
//  normal Command shortcuts (Cmd+C, Cmd+V, ...) always involve a second key,
//  which we explicitly disqualify.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Constants + display text for the single hardcoded trigger that opens the
/// Ask Window. The trigger itself is a double-tap of either Command key; the
/// stateful detection lives in `GlobalAskShortcutMonitor` because a double-tap
/// spans several events over time.
enum AskShortcut {
    /// Kept for source compatibility with the transition pipeline. Only
    /// `.pressed` is ever sent now (once per detected double-tap).
    enum Transition {
        case none
        case pressed
        case released
    }

    static let displayText = "double-tap ⌘"

    /// Virtual keycodes for the Command keys (kVK_Command / kVK_RightCommand).
    /// Either one counts — the user can double-tap with whichever thumb.
    static let leftCommandKeyCode: UInt16 = 55
    static let rightCommandKeyCode: UInt16 = 54

    /// Maximum seconds allowed between the two taps for them to count as a
    /// double-tap. Roughly matches a comfortable double-click feel.
    static let doubleTapMaxInterval: TimeInterval = 0.4
}

final class GlobalAskShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<AskShortcut.Transition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    // MARK: - Double-tap detection state
    // All of this is mutated exclusively from the CGEvent tap callback, which
    // runs on `CFRunLoopGetMain()` and therefore always on the main thread.

    /// Whether a Command key is currently held down.
    private var commandKeyIsDown = false
    /// Whether any other key (or modifier) was pressed while Command was held,
    /// which means this was a Command+key chord, not a lone Command tap.
    private var anotherKeyPressedWhileCommandDown = false
    /// `systemUptime` of the last clean (lone) Command tap, used to measure the
    /// gap to the next tap. `0` means "no pending first tap".
    private var lastCleanCommandTapTime: TimeInterval = 0

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        guard globalEventTap == nil else { return }

        // We watch key presses (to disqualify Command+key chords) and modifier
        // changes (to see the Command key itself go down and up).
        let monitoredEventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
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
            print("⚠️ Global ask trigger: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global ask trigger: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        commandKeyIsDown = false
        anotherKeyPressedWhileCommandDown = false
        lastCleanCommandTapTime = 0

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

        switch eventType {
        case .keyDown:
            // A real key pressed while Command is held makes this a Command+key
            // chord (like Cmd+C), not a lone Command tap, so disqualify it. Any
            // keystroke also breaks an in-progress double-tap's timing.
            if commandKeyIsDown {
                anotherKeyPressedWhileCommandDown = true
            }
            lastCleanCommandTapTime = 0

        case .flagsChanged:
            handleModifierFlagsChanged(keyCode: eventKeyCode, flags: event.flags)

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    /// Tracks the Command key going down and up, and fires `.pressed` when two
    /// clean (lone) Command taps land within `doubleTapMaxInterval`.
    private func handleModifierFlagsChanged(keyCode: UInt16, flags: CGEventFlags) {
        let isCommandKey = (keyCode == AskShortcut.leftCommandKeyCode
            || keyCode == AskShortcut.rightCommandKeyCode)

        // A different modifier (Shift/Control/Option/Fn) changing while Command
        // is held means a chord is forming, so disqualify the tap.
        guard isCommandKey else {
            if commandKeyIsDown {
                anotherKeyPressedWhileCommandDown = true
            }
            return
        }

        let commandFlagIsNowSet = flags.contains(.maskCommand)

        if commandFlagIsNowSet && !commandKeyIsDown {
            // Rising edge: a Command key just went down.
            commandKeyIsDown = true
            anotherKeyPressedWhileCommandDown = false
        } else if !commandFlagIsNowSet && commandKeyIsDown {
            // Falling edge: Command just came up, completing a press.
            commandKeyIsDown = false

            guard !anotherKeyPressedWhileCommandDown else {
                // It was Command+something, not a lone tap.
                lastCleanCommandTapTime = 0
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCleanCommandTapTime <= AskShortcut.doubleTapMaxInterval {
                // Second clean tap inside the window — this is the double-tap.
                lastCleanCommandTapTime = 0
                shortcutTransitionPublisher.send(.pressed)
            } else {
                // First clean tap — start (or restart) the double-tap timer.
                lastCleanCommandTapTime = now
            }
        }
    }
}
