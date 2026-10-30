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
}
