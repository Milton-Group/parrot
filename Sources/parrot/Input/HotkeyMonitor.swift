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
    /// The key's own device-specific modifier bit, for keys whose `mask` is
    /// shared with their opposite-hand twin. macOS ORs these raw bits into the
    /// same flags word: NX_DEVICERALTKEYMASK (0x40) is the right Option key
    /// alone, so a right-option hold stays observable — and its release
    /// detectable — while the left Option key is also down.
    let deviceMask: UInt64?

    static let fn = HotkeySpec(name: "fn", mask: .maskSecondaryFn, keycode: nil, deviceMask: nil)
    static let rightOption = HotkeySpec(
        name: "right-option", mask: .maskAlternate, keycode: 61, deviceMask: 0x40
    )

    static let defaults: [HotkeySpec] = [fn, rightOption]
    static let defaultNames = "fn,right-option"

    /// Whether this key is physically down in the given flags word.
    func isDown(in flags: CGEventFlags) -> Bool {
        if let deviceMask { return flags.rawValue & deviceMask != 0 }
        return flags.contains(mask)
    }

    /// Parses a comma-separated list, matching names case-insensitively after
    /// trimming. Empty tokens are skipped, so a trailing comma costs nothing.
    /// An unknown name warns and is dropped, keeping whatever else parsed; the
    /// compiled default is used only when nothing valid remains, rather than
    /// exiting — a typo in the fleet's launch arguments must not leave every
    /// re-running Mac with a daemon that refuses to start.
    static func parse(_ raw: String) -> [HotkeySpec] {
        var specs: [HotkeySpec] = []
        var unknown: [String] = []

        for token in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            switch name {
            case fn.name:
                if !specs.contains(where: { $0.name == fn.name }) { specs.append(fn) }
            case rightOption.name:
                if !specs.contains(where: { $0.name == rightOption.name }) { specs.append(rightOption) }
            default:
                unknown.append(name)
            }
        }

        for name in unknown {
            let fallback = specs.isEmpty
                ? "using default \(defaultNames)"
                : "keeping \(specs.map(\.name).joined(separator: ","))"
            FileHandle.standardError.write(Data(
                "hotkey: unknown name \"\(name)\", \(fallback)\n".utf8
            ))
        }
        return specs.isEmpty ? defaults : specs
    }
}

/// Watches the configured push-to-talk keys and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum CancelReason: String {
        case chord
        case short
        case tapDisabled = "tap-disabled"
    }
    enum Event { case pressed, released, cancelled(CancelReason) }
    enum HotkeyError: Error { case tapCreateFailed }

    /// A hold shorter than this is a stray tap, not dictation.
    private static let minimumHold: TimeInterval = 0.3

    /// Left/right modifier keycodes. A hotkey is one of these, so its own state
    /// must never count as a chord.
    private static let modifierKeycodes: ClosedRange<CGKeyCode> = 54...63
    private static let highestKeycode: CGKeyCode = 127

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
    /// Set while we are the ones turning the chord tap off. macOS reports a
    /// programmatic disable as `tapDisabledByUserInput`, which is otherwise the
    /// system telling us our tap stalled.
    private var selfDisabling = false
    /// Index into `specs` of the key currently holding the capture, if any.
    /// Whichever key goes down first owns the hold until it comes back up.
    private var activeIndex: Int?
    private var pressedTimestamp: CGEventTimestamp?
    private var reEnables: [Date] = []
    private var alertedThisWindow = false
    /// Last flags word seen, so a press is a rising edge rather than "the flag
    /// is still set" — otherwise a cancelled hold re-arms on the next unrelated
    /// modifier event while the key is still held down.
    private var previousFlags: CGEventFlags = []
    /// A cancelled hotkey may not own another hold until its own key comes up.
    private var cancelledIndex: Int?

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

        // The chord tap is created here rather than per hold: `tapCreate` is
        // TCC-gated and slow, and doing it from the hotkey callback put that
        // latency in front of every recording. Its mask is far too chatty to
        // leave listening — scroll momentum alone delivers hundreds of events a
        // second, and every event macOS hands us counts against the budget it
        // uses to decide our tap has stalled — so it lives disabled and is
        // enabled only for the length of a hold.
        guard let chordTap = makeTap(mask: HotkeyMonitor.chordMask) else {
            FileHandle.standardError.write(Data("tap: chord tap creation failed\n".utf8))
            throw HotkeyError.tapCreateFailed
        }
        let chordSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, chordTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), chordSource, .commonModes)

        self.tap = tap
        self.runLoopSource = source
        self.chordTap = chordTap
        self.chordSource = chordSource
        setChordTap(enabled: false)
        syncFlagsState()
    }

    func stop() {
        // Clears any hold in flight and puts the chord tap back to sleep. No
        // event is emitted for it: the microphone is released by the handler
        // Parrot installs, on the release or cancel edge, and by then the
        // process is on its way down anyway.
        endHold()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let chordTap { CFMachPortInvalidate(chordTap) }
        if let chordSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), chordSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        chordTap = nil
        chordSource = nil
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

    private func setChordTap(enabled: Bool) {
        guard let chordTap else { return }
        // The flag is raised before the disable and stays up until the next
        // enable, because the disable notification can arrive on a later run
        // loop turn than the call that caused it.
        selfDisabling = !enabled
        CGEvent.tapEnable(tap: chordTap, enable: enabled)
    }

    /// Whether the chord tap is off because we turned it off.
    fileprivate var isSelfDisabling: Bool { selfDisabling }

    /// Called from the tap callback when macOS disables our tap. Without this
    /// the process keeps running, the menu bar icon stays put, and the hotkey
    /// silently does nothing until the user restarts parrot. The callback cannot
    /// say which of our taps was disabled, so the hotkey tap — the one that has
    /// to be listening at all times — is the one revived.
    fileprivate func reEnable(reason: String) {
        // A hold cannot survive its tap being disabled: the release edge would
        // never arrive, so the microphone would stay open and the hotkey would
        // be dead until the process restarted. End it, discarding the audio.
        // That also puts the chord tap back to its resting state, disabled,
        // which is where it belongs now that no hold is running; the next hold
        // enables it again, and enabling is what revives a disabled tap.
        cancelHold(.tapDisabled)

        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            FileHandle.standardError.write(Data("tap: re-enable FAILED (\(reason))\n".utf8))
        }
        syncFlagsState()

        let now = Date()
        reEnables.removeAll { now.timeIntervalSince($0) > HotkeyMonitor.reEnableWindow }
        if reEnables.count <= HotkeyMonitor.reEnableAlertCount { alertedThisWindow = false }
        reEnables.append(now)
        FileHandle.standardError.write(Data("tap: re-enabled (\(reason))\n".utf8))
        // Say it once per window, not once per event, and keep re-enabling
        // either way: the LaunchAgent restarts the process, so exiting here
        // would only trade a noisy log for a restart loop.
        if reEnables.count > HotkeyMonitor.reEnableAlertCount, !alertedThisWindow {
            alertedThisWindow = true
            let minutes = Int(HotkeyMonitor.reEnableWindow / 60)
            let line = "tap: re-enabled \(reEnables.count) times in the last \(minutes) minutes — "
                + "the hotkey may be missing events\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug { debugLog(type: type, event: event) }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .scrollWheel:
            // Momentum frames are the system coasting after the fingers left the
            // trackpad, not a new user action — and they arrive by the hundred.
            guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
            cancelHold()
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            cancelHold()
        default:
            break
        }
    }

    /// Only flagsChanged gets a keycode: it identifies a modifier key, which is
    /// the thing being debugged. A keyDown's keycode is what the user is typing
    /// — passwords included — and a mouse event's payload is the cursor
    /// position, so those log the event type and nothing else.
    private func debugLog(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] flagsChanged keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        default:
            FileHandle.standardError.write(Data("  [debug] type=\(type.rawValue)\n".utf8))
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let previous = previousFlags
        previousFlags = flags

        if let latched = cancelledIndex, !specs[latched].isDown(in: flags) {
            cancelledIndex = nil
        }

        if let index = activeIndex {
            guard !specs[index].isDown(in: flags) else { return }
            let held = holdDuration(endingAt: event.timestamp)
            endHold()
            emit(held < HotkeyMonitor.minimumHold ? .cancelled(.short) : .released)
            return
        }

        for (index, spec) in specs.enumerated() {
            guard cancelledIndex != index else { continue }
            guard !spec.isDown(in: previous), spec.isDown(in: flags) else { continue }
            if let wanted = spec.keycode, keycode != wanted { continue }
            beginHold(index: index, at: event.timestamp)
            return
        }
    }

    private func beginHold(index: Int, at timestamp: CGEventTimestamp) {
        // Arm the tap before scanning, not after: a key pressed in between would
        // be missed by both. A key already down when the hotkey went down is one
        // this monitor will never see come up, so fail the hold closed.
        setChordTap(enabled: true)
        activeIndex = index
        pressedTimestamp = timestamp
        if nonModifierKeyIsDown() {
            cancelHold(.chord)
            return
        }
        emit(.pressed)
    }

    /// Both the rising-edge test and the cancel latch read from the last flags
    /// word seen. Any event missed — before the tap existed, or while it was
    /// disabled — would leave that word, and a latch keyed off it, stuck; the
    /// live modifier state is the ground truth to re-seed them from.
    private func syncFlagsState() {
        let live = CGEventSource.flagsState(.combinedSessionState)
        previousFlags = live
        if let latched = cancelledIndex, !specs[latched].isDown(in: live) {
            cancelledIndex = nil
        }
    }

    private func nonModifierKeyIsDown() -> Bool {
        for key in CGKeyCode(0)...HotkeyMonitor.highestKeycode {
            if HotkeyMonitor.modifierKeycodes.contains(key) { continue }
            if CGEventSource.keyState(.combinedSessionState, key: key) { return true }
        }
        return false
    }

    /// A CGEvent timestamp is nanoseconds since startup, so the delta needs no
    /// timebase conversion. Hold length is measured from the timestamps rather
    /// than from wall-clock time in the handler, which drifts with however long
    /// the run loop took to get here.
    private func holdDuration(endingAt timestamp: CGEventTimestamp) -> TimeInterval {
        guard let pressedTimestamp, timestamp > pressedTimestamp else { return 0 }
        return Double(timestamp - pressedTimestamp) / 1_000_000_000
    }

    private func cancelHold(_ reason: CancelReason = .chord) {
        guard let index = activeIndex else { return }
        cancelledIndex = index
        endHold()
        emit(.cancelled(reason))
    }

    private func endHold() {
        activeIndex = nil
        pressedTimestamp = nil
        setChordTap(enabled: false)
    }

    /// Tap and hold state are settled inline in the tap callback; only the
    /// capture and UI work the handler does is handed to the main queue.
    private func emit(_ event: Event) {
        guard let onEvent else { return }
        DispatchQueue.main.async { onEvent(event) }
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

    // The run loop source is on the main run loop, so this callback already
    // runs on the thread that owns both taps: hold state and tap enable/disable
    // are settled here, synchronously. Deferring them to the next run loop turn
    // left a window in which the chord tap was not yet listening and a keystroke
    // chorded with the hotkey went unseen.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Turning the chord tap off between holds is reported the same way as
        // the system disabling us for user input. Ours is neither counted nor
        // "recovered" from.
        if type == .tapDisabledByUserInput, monitor.isSelfDisabling {
            return Unmanaged.passUnretained(event)
        }
        monitor.reEnable(reason: type == .tapDisabledByTimeout ? "timeout" : "user input")
        return Unmanaged.passUnretained(event)
    }

    monitor.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
