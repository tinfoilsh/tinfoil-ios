import Foundation
import Testing
@testable import TinfoilChat

@Suite("PII protection defaults")
struct PIIProtectionDefaultsTests {
    @Test("missing UserDefaults value defaults on and explicit false is preserved") @MainActor
    func userDefaultsBehavior() throws {
        let suiteName = "pii-protection-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsManager.loadPIICheckEnabled(from: defaults))
        defaults.set(false, forKey: Constants.StorageKeys.Settings.piiCheckEnabled)
        #expect(!SettingsManager.loadPIICheckEnabled(from: defaults))
    }

    @Test("profile field defaults on when missing and preserves false")
    func profileBehavior() throws {
        let missing = try JSONDecoder().decode(ProfileData.self, from: Data("{}".utf8))
        let disabled = try JSONDecoder().decode(
            ProfileData.self,
            from: Data(#"{"piiCheckEnabled":false}"#.utf8)
        )
        let encodedDisabled = try JSONEncoder().encode(disabled)
        let object = try #require(
            JSONSerialization.jsonObject(with: encodedDisabled) as? [String: Any]
        )

        #expect(missing.effectivePIICheckEnabled)
        #expect(!disabled.effectivePIICheckEnabled)
        #expect(ProfileDefaults.profile.piiCheckEnabled == true)
        #expect(object["piiCheckEnabled"] as? Bool == false)
    }
}
