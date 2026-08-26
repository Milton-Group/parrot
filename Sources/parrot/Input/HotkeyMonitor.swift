import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One push-to-talk key: the modifier flag it raises and, where the left and
/// right variants of a modifier share a flag, the keycode that tells them apart.
struct HotkeySpec {
    let name: String
    let mask: CGEventFlags
    let keycode: Int64?

    static let fn = HotkeySpec(name: "fn", mask: .maskSecondaryFn, keycode: nil)
    static let rightOption = HotkeySpec(name: "right-option", mask: .maskAlternate, keycode: 61)

    static let defaults: [HotkeySpec] = [fn, rightOption]
    static let defaultNames = "fn,right-option"

    /// Parses a comma-separated list, matching names case-insensitively after
    /// trimming. An unknown name warns and falls back to the compiled default
    /// rather than exiting: a typo in the fleet's launch arguments must not
    /// leave every re-running Mac with a daemon that refuses to start.
    static func parse(_ raw: String) -> [HotkeySpec] {
        var specs: [HotkeySpec] = []
        var unknown: [String] = []

        for token in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            switch name {
            case fn.name:
                if !specs.contains(where: { $0.name == fn.name }) { specs.append(fn) }
            case rightOption.name:
                if !specs.contains(where: { $0.name == rightOption.name }) { specs.append(rightOption) }
            default:
                unknown.append(name)
            }
        }

        guard unknown.isEmpty, !specs.isEmpty else {
            for name in unknown {
                FileHandle.standardError.write(Data(
                    "hotkey: unknown name \"\(name)\", using default \(defaultNames)\n".utf8
                ))
            }
            return defaults
        }
        return specs
    }
}

/// Watches the configured push-to-talk keys and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum CancelReason: String { case chord, short }
    enum Event { case pressed, released, cancelled(CancelReason) }
    enum HotkeyError: Error { case tapCreateFailed }

    /// A hold shorter than this is a stray tap, not dictation.
    private static let minimumHold: TimeInterval = 0.3

    /// Repeated re-enables mean the tap keeps stalling; say so loudly rather
    /// than leaving one quiet line per event in a log nobody reads.
    private static let reEnableWindow: TimeInterval = 600
    private static let reEnableAlertCount = 5

    private static let chordMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.scrollWheel.rawValue)

    private let specs: [HotkeySpec]
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var chordTap: CFMachPort?
    private var chordSource: CFRunLoopSource?
    /// Index into `specs` of the key currently holding the capture, if any.
    /// Whichever key goes down first owns the hold until it comes back up.
    private var activeIndex: Int?
    private var pressedAt: Date?
    private var reEnables: [Date] = []

    init(specs: [HotkeySpec] = HotkeySpec.defaults, debug: Bool = false) {
        self.specs = specs.isEmpty ? HotkeySpec.defaults : specs
        self.debug = debug
    }

    var activeNames: String { specs.map(\.name).joined(separator: ",") }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        // Only flagsChanged drives the hotkey. keyDown/keyUp are subscribed here
        // *only* under --debug-hotkey: listening to every keystroke system-wide
        // costs main-thread work, raises the odds macOS disables the tap for
        // timeout, and needlessly exposes typed content (including password
        // fields) to an Accessibility-privileged process. Chord-cancel gets its
        // keyDown from the hold-scoped tap instead.
        var mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        if debug {
            mask |=
                (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
        }
        guard let tap = makeTap(mask: mask) else { throw HotkeyError.tapCreateFailed }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        stopChordTap()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    private func makeTap(mask: CGEventMask) -> CFMachPort? {
        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Clicks, scrolls and keystrokes cancel a hold, but they are far too chatty
    /// to leave in a permanently installed mask: scroll momentum alone delivers
    /// hundreds of events a second, and every event macOS hands us counts
    /// against the budget it uses to decide our tap has stalled. So the wide
    /// mask lives in a second tap that exists only while a hotkey is held.
    private func startChordTap() {
        guard chordTap == nil, let tap = makeTap(mask: HotkeyMonitor.chordMask) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        chordTap = tap
        chordSource = source
    }

    private func stopChordTap() {
        if let chordTap {
            CGEvent.tapEnable(tap: chordTap, enable: false)
        }
        if let chordSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), chordSource, .commonModes)
        }
        chordTap = nil
        chordSource = nil
    }

    /// Called from the tap callback when macOS disables our tap. Without this
    /// the process keeps running, the menu bar icon stays put, and the hotkey
    /// silently does nothing until the user restarts parrot. The callback
    /// cannot say which of our taps was disabled, so both are re-enabled.
    fileprivate func reEnable(reason: String) {
        var reEnabled = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            reEnabled = true
        }
        if let chordTap {
            CGEvent.tapEnable(tap: chordTap, enable: true)
            reEnabled = true
        }
        guard reEnabled else { return }

        let now = Date()
        reEnables.removeAll { now.timeIntervalSince($0) > HotkeyMonitor.reEnableWindow }
        reEnables.append(now)
        FileHandle.standardError.write(Data("tap: re-enabled (\(reason))\n".utf8))
        if reEnables.count >= HotkeyMonitor.reEnableAlertCount {
            let minutes = Int(HotkeyMonitor.reEnableWindow / 60)
            FileHandle.standardError.write(Data(
                "tap: re-enabled \(reEnables.count) times in the last \(minutes) minutes\n".utf8
            ))
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug { debugLog(type: type, event: event) }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            cancelHold()
        default:
            break
        }
    }

    /// Keycodes and modifier flags are only meaningful for keyboard events, and
    /// a mouse event's payload is its cursor position — never logged, not even
    /// under --debug-hotkey.
    private func debugLog(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged, .keyDown, .keyUp:
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        default:
            FileHandle.standardError.write(Data("  [debug] type=\(type.rawValue)\n".utf8))
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        for (index, spec) in specs.enumerated() {
            if let wanted = spec.keycode, keycode != wanted { continue }
            let pressed = event.flags.contains(spec.mask)
            if activeIndex == nil, pressed {
                activeIndex = index
                pressedAt = Date()
                startChordTap()
                onEvent?(.pressed)
                return
            }
            if activeIndex == index, !pressed {
                let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
                endHold()
                onEvent?(held < HotkeyMonitor.minimumHold ? .cancelled(.short) : .released)
                return
            }
        }
    }

    private func cancelHold() {
        guard activeIndex != nil else { return }
        endHold()
        onEvent?(.cancelled(.chord))
    }

    private func endHold() {
        activeIndex = nil
        pressedAt = nil
        stopChordTap()
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        // The tap must be re-enabled from the run loop that owns it.
        DispatchQueue.main.async { monitor.reEnable(reason: reason) }
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
