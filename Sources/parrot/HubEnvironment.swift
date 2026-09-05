import Darwin

enum HubEnvironment {
    private static let variableNames = [
        "HF_ENDPOINT",
        "HF_TOKEN",
        "HUGGING_FACE_HUB_TOKEN",
        "HF_TOKEN_PATH",
        "HF_HOME",
    ]

    static func sanitize() {
        for name in variableNames {
            unsetenv(name)
        }
    }
}
