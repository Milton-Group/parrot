import Foundation

/// What this build expects to find in its model store, as the release step
/// publishes it beside the tarball (`parrot-model-spec.json`). Built from the
/// same registry and store paths `run` checks before loading, so a consumer
/// that pins a model tree (the Milton bootstrap) can refuse one that does not
/// match the pinned binary instead of trusting a hand-copied id. Paths are
/// relative to the store; the output is byte-stable for a given build.
struct ModelSpec: Encodable {
    struct Store: Encodable {
        /// The default store with the home directory written as `~`.
        let defaultPath: String
        let root: String

        enum CodingKeys: String, CodingKey {
            case defaultPath = "default_path"
            case root
        }
    }

    struct Model: Encodable {
        let id: String
        let whisperKitID: String
        let variantPath: String
        let variantPieces: [String]
        let tokenizerRepo: String?
        let tokenizerPath: String?
        let tokenizerPieces: [String]

        // Spelled out, not derived from the property names: these keys are the
        // contract a consumer binds to, and a Swift rename must not move them.
        // A model without a tokenizer omits tokenizer_repo and tokenizer_path.
        enum CodingKeys: String, CodingKey {
            case id
            case whisperKitID = "whisper_kit_id"
            case variantPath = "variant_path"
            case variantPieces = "variant_pieces"
            case tokenizerRepo = "tokenizer_repo"
            case tokenizerPath = "tokenizer_path"
            case tokenizerPieces = "tokenizer_pieces"
        }
    }

    /// Bumped when a field changes meaning or goes away; adding one does not.
    let schema = 1
    let store: Store
    let defaultModel: String?
    let models: [Model]

    enum CodingKeys: String, CodingKey {
        case schema, store, models
        case defaultModel = "default_model"
    }

    static func current() -> ModelSpec {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = ModelStore.defaultBase().path
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        return ModelSpec(
            store: Store(defaultPath: path, root: ModelStore.root),
            defaultModel: ModelRegistry.recommended()?.id,
            // Only WhisperKit models have a store layout to describe.
            models: ModelRegistry.shared.compactMap { m in
                guard let id = m.whisperKitID else { return nil }
                return Model(
                    id: m.id,
                    whisperKitID: id,
                    variantPath: ModelStore.variantPath(whisperKitID: id),
                    variantPieces: ModelStore.requiredPieces,
                    tokenizerRepo: m.tokenizerRepo,
                    tokenizerPath: m.tokenizerRepo.map(ModelStore.tokenizerPath(repo:)),
                    tokenizerPieces: m.tokenizerRepo == nil ? [] : ModelStore.tokenizerPieces
                )
            }
        )
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}
