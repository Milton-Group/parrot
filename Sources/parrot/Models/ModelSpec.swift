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
    }

    struct Model: Encodable {
        let id: String
        let whisperKitID: String
        let variantPath: String
        let variantPieces: [String]
        let tokenizerRepo: String?
        let tokenizerPath: String?
        let tokenizerPieces: [String]
    }

    /// Bumped when a field changes meaning or goes away; adding one does not.
    let schema = 1
    let store: Store
    let defaultModel: String?
    let models: [Model]

    static func current() -> ModelSpec {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = ModelStore.defaultBase().path
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        return ModelSpec(
            store: Store(defaultPath: path, root: "models"),
            defaultModel: ModelRegistry.recommended()?.id,
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
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}
