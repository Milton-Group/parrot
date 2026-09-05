import Darwin
import Foundation
@testable import parrot
import XCTest

final class HubEnvironmentTests: XCTestCase {
    func testSanitizeRemovesHubOverridesAndPreservesUnrelatedVariables() {
        let targetedNames = [
            "HF_ENDPOINT",
            "HF_TOKEN",
            "HUGGING_FACE_HUB_TOKEN",
            "HF_TOKEN_PATH",
            "HF_HOME",
        ]
        let unrelatedName = "PARROT_HUB_ENVIRONMENT_TEST"
        let names = targetedNames + [unrelatedName]
        let originalValues = Dictionary(uniqueKeysWithValues: names.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        })
        defer {
            for (name, value) in originalValues {
                if let value {
                    setenv(name, value, 1)
                } else {
                    unsetenv(name)
                }
            }
        }

        for name in targetedNames {
            setenv(name, "hostile-test-value", 1)
        }
        setenv(unrelatedName, "preserved-test-value", 1)

        HubEnvironment.sanitize()

        for name in targetedNames {
            XCTAssertNil(ProcessInfo.processInfo.environment[name], "expected \(name) to be removed")
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment[unrelatedName], "preserved-test-value")
    }
}
