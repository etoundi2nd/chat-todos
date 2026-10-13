import AppKit
import CoreGraphics

/// Watches the keyboard system-wide for a quick double tap of a lone Shift key.
/// Needs Accessibility access (a listen-only event tap); it never modifies events.
final class ShiftTapMonitor {
    static let leftShift: Int64 = 56
    static let rightShift: Int64 = 60

    var onLeftDouble: (@MainActor () -> Void)?
    var onRightDouble: (@MainActor () -> Void)?

    /// Max time a tap may be held, and max gap between the two taps.
    var holdLimit: TimeInterval = 0.3
    var gapLimit: TimeInterval = 0.35

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var isDown = false
    private var downKey: Int64 = -1
    private var pressTime: TimeInterval = 0
    private var lastKey: Int64 = -1
    private var lastRelease: TimeInterval = 0
    private var taps = 0

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<ShiftTapMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func reset() {
        isDown = false
        taps = 0
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return reset() }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == Self.leftShift || code == Self.rightShift else { return reset() }
        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
            return reset()
        }

        // Device-dependent bits tell left and right shift apart.
        let deviceBit: UInt64 = code == Self.leftShift ? 0x02 : 0x04
        let pressed = flags.rawValue & deviceBit != 0
        let now = ProcessInfo.processInfo.systemUptime

        if pressed {
            if isDown { return reset() } // both shifts held
            if taps == 1 && (code != lastKey || now - lastRelease > gapLimit) { taps = 0 }
            isDown = true
            downKey = code
            pressTime = now
        } else {
            guard isDown, code == downKey else { return reset() }
            isDown = false
            guard now - pressTime <= holdLimit else {
                taps = 0
                return
            }
            taps += 1
            lastKey = code
            lastRelease = now
            if taps == 2 {
                taps = 0
                let handler = code == Self.leftShift ? onLeftDouble : onRightDouble
                Task { @MainActor in handler?() }
            }
        }
    }
}
