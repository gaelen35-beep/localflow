import CoreGraphics
import Foundation

/// Push-to-talk on a single modifier key. Uses a listen-only event tap, so it needs Input Monitoring
/// permission but never swallows keystrokes.
final class HotkeyMonitor {
    /// Right Option (keyCode 61): dictate with cleanup.
    static func rightOption() -> HotkeyMonitor { HotkeyMonitor(keyCode: 61, flag: .maskAlternate) }
    /// Right Command (keyCode 54): dictate raw, no cleanup.
    static func rightCommand() -> HotkeyMonitor { HotkeyMonitor(keyCode: 54, flag: .maskCommand) }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private let keyCode: Int64
    private let flag: CGEventFlags
    private var tap: CFMachPort?
    private var isDown = false

    init(keyCode: Int64, flag: CGEventFlags) {
        self.keyCode = keyCode
        self.flag = flag
    }

    /// Returns false if the tap could not be created (usually: permission not granted yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
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
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }

        let down = event.flags.contains(flag)
        if down && !isDown {
            isDown = true
            onPress?()
        } else if !down && isDown {
            isDown = false
            onRelease?()
        }
    }
}
