import CoreGraphics
import Foundation

/// Stamped into `eventSourceUserData` on every event parrot posts, so parrot's
/// own event taps can tell an injected keystroke from one the user typed.
enum ParrotEventTag {
    static let injected: Int64 = 0x5041_5252_4F54
}

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Injected events carry the tag, and a private state so the synthetic key
    /// presses do not merge into the keyboard state the rest of the system sees.
    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = ParrotEventTag.injected
        return source
    }()

    /// True while `inject` is posting. Read on the main thread only, which is
    /// also the only thread that writes it.
    private(set) static var isInjecting = false

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        let sanitized = sanitize(text)
        guard !sanitized.isEmpty else { return }

        let utf16 = Array(sanitized.utf16)
        let chunkSize = 20
        var index = 0

        isInjecting = true
        defer { isInjecting = false }
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    /// Control characters and the line and paragraph separators become a single
    /// space, and runs of whitespace then collapse. Injecting them literally
    /// would submit whatever field the cursor is in — a shell prompt, a chat
    /// box, a form — but dropping them outright welds the words on either side
    /// together.
    ///
    /// Format characters are dropped: the zero-width spaces and direction marks
    /// are invisible padding, and the bidi overrides and isolates can make
    /// injected text read as something other than what was injected. The
    /// exceptions are the zero-width non-joiner and joiner, which are ordinary
    /// spelling in Indic and Arabic scripts and hold emoji sequences together.
    private static func sanitize(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                kept.append(" ")
            case .format:
                if scalar == "\u{200C}" || scalar == "\u{200D}" { kept.append(scalar) }
            default:
                kept.append(scalar)
            }
        }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
