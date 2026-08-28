import Foundation

/// Where downloaded models live. WhisperKit's own default is
/// `~/Documents/huggingface`, which macOS guards behind a Files & Folders
/// prompt and iCloud may sync or evict; a daemon's model cache belongs under
/// Application Support. There is deliberately no fallback to the old
/// location: the daemon must never touch `~/Documents`.
enum ModelStore {
    /// The CoreML pieces WhisperKit needs to load a variant; a folder missing
    /// any of them is a torn download, not a model.
    static let requiredPieces = [
        "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json",
    ]

    static func defaultBase() -> URL {
        URL.applicationSupportDirectory.appending(path: "parrot", directoryHint: .isDirectory)
    }

    /// WhisperKit's layout beneath the base: models/argmaxinc/whisperkit-coreml/<variant>.
    static func variantFolder(base: URL, whisperKitID: String) -> URL {
        base.appending(path: "models/argmaxinc/whisperkit-coreml/\(whisperKitID)", directoryHint: .isDirectory)
    }

    /// The tokenizer WhisperKit pairs with a variant: models/<repo>/tokenizer.json.
    static func tokenizerFile(base: URL, repo: String) -> URL {
        base.appending(path: "models/\(repo)/tokenizer.json")
    }

    /// The first file a load would need that is not on disk, or nil when the
    /// store holds everything for this model.
    static func missingPiece(base: URL, model: TranscriptionModel) -> String? {
        guard let id = model.whisperKitID else { return nil }
        let folder = variantFolder(base: base, whisperKitID: id)
        for piece in requiredPieces {
            let path = folder.appending(path: piece).path
            if !FileManager.default.fileExists(atPath: path) { return path }
        }
        if let repo = model.tokenizerRepo {
            let path = tokenizerFile(base: base, repo: repo).path
            if !FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// The operator's `--model-dir` (tilde allowed) or the default. Only the
    /// download path creates it: the daemon reads, and a store it cannot
    /// create is a store it cannot load from either.
    static func resolve(_ override: String?, create: Bool) throws -> URL {
        let base: URL
        if let override, !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = defaultBase()
        }
        if create {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }
}
