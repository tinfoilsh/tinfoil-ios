import Testing
@testable import TinfoilChat

@Suite("Start fresh confirmation")
struct StartFreshConfirmationTests {
    @Test func confirmationIsRequiredOnlyDuringRecovery() {
        #expect(StartFreshConfirmation.isRequired(for: .recovery))
        #expect(!StartFreshConfirmation.isRequired(for: .setup))
    }

    @Test func warningExplainsTheRecoveryRisk() {
        #expect(StartFreshConfirmation.title == "Start Fresh?")
        #expect(StartFreshConfirmation.warning.contains("new encryption key"))
        #expect(StartFreshConfirmation.warning.contains("lose access"))
    }
}
