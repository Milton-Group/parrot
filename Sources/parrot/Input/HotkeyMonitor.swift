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

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            cancelHold()
        default:
            break
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
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart parrot.
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
