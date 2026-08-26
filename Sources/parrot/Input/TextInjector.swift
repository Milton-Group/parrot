import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        let sanitized = stripControlCharacters(text)
        guard !sanitized.isEmpty else { return }

        let utf16 = Array(sanitized.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    /// Drops C0/C1 control characters, tab and newline included. A transcript
    /// that contains a newline would otherwise submit whatever field the cursor
    /// happens to be in — a shell prompt, a chat box, a form.
    private static func stripControlCharacters(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x00...0x1F, 0x7F, 0x80...0x9F: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(kept))
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
