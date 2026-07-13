import XCTest
import NovelCore
@testable import LongformStudio

@MainActor
final class LongformStudioTests: XCTestCase {
    func testEndpointRejectsPlainHTTP() {
        let profile = AIEndpointProfile(name: "Local", endpoint: URL(string: "http://192.168.1.2/v1/chat/completions")!, model: "model")
        XCTAssertFalse(profile.isSecure)
    }

    func testDiagnosticRedactionRemovesAuthorizationAndAPIKey() {
        let input = "Authorization: Bearer sk-sensitive api_key=another-secret"
        let output = DiagnosticLogger.redactAuthorization(input)
        XCTAssertFalse(output.contains("sk-sensitive"))
        XCTAssertFalse(output.contains("another-secret"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testSettingsNeverSerializeKeyMaterial() throws {
        let suiteName = "LongformStudioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let profile = AIEndpointProfile(name: "Test", endpoint: URL(string: "https://example.com/v1/chat/completions")!, model: "model")
        try store.save(profile: profile, apiKey: nil)
        let data = try XCTUnwrap(defaults.data(forKey: "settings.v1"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("secret"))
    }
}
