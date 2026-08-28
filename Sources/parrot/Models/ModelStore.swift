import Foundation

/// Where downloaded models live. WhisperKit's own default is
/// `~/Documents/huggingface`, which macOS guards behind a Files & Folders
/// prompt and iCloud may sync or evict; a daemon's model cache belongs under
/// Application Support. There is deliberately no fallback to the old
/// location: the daemon must never touch `~/Documents`.
enum ModelStore {
    static func defaultBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appending(path: "parrot", directoryHint: .isDirectory)
    }

    /// WhisperKit's layout beneath the base: models/argmaxinc/whisperkit-coreml/<variant>.
    static func variantFolder(base: URL, whisperKitID: String) -> URL {
        base.appending(path: "models/argmaxinc/whisperkit-coreml/\(whisperKitID)", directoryHint: .isDirectory)
    }

    /// The operator's `--model-dir` (tilde allowed) or the default, created if
    /// missing so WhisperKit's downloader has a base to write under.
    static func resolve(_ override: String?) throws -> URL {
        let base: URL
        if let override, !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = defaultBase()
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
