import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct AuthenticatorMFAViewModelTests {
    @Test
    func enrollmentVerifiesAndPreservesBackupCodes() async {
        let recorder = Recorder()
        let service = StubService(
            createTOTP: {
                AuthenticatorMFASetupDetails(secret: "SECRET", uri: "otpauth://totp/example")
            },
            verifyTOTP: { code in
                recorder.verificationCodes.append(code)
                return ["alpha", "bravo"]
            }
        )
        let model = AuthenticatorMFAViewModel(service: service)
        model.sync(userId: "user-1", isEnabled: false)

        let didStart = await model.startSetup()
        #expect(didStart)
        #expect(model.setupDetails?.secret == "SECRET")

        model.verificationCode = "123456"
        let didVerify = await model.verifySetup()
        #expect(didVerify)
        #expect(recorder.verificationCodes == ["123456"])
        #expect(model.isEnabled)
        #expect(model.setupDetails == nil)
        #expect(model.backupCodes == ["alpha", "bravo"])
    }

    @Test
    func invalidCodeLengthDoesNotCallTheService() async {
        let recorder = Recorder()
        let model = AuthenticatorMFAViewModel(
            service: StubService(verifyTOTP: { code in
                recorder.verificationCodes.append(code)
                return []
            })
        )
        model.verificationCode = "12345"

        let didVerify = await model.verifySetup()
        #expect(didVerify == false)
        #expect(recorder.verificationCodes.isEmpty)
    }

    @Test
    func nonAsciiCodeDoesNotCallTheService() async {
        let recorder = Recorder()
        let model = AuthenticatorMFAViewModel(
            service: StubService(verifyTOTP: { code in
                recorder.verificationCodes.append(code)
                return []
            })
        )
        model.verificationCode = "１２３４５６"

        let didVerify = await model.verifySetup()

        #expect(didVerify == false)
        #expect(recorder.verificationCodes.isEmpty)
    }

    @Test
    func disablingClearsAuthenticatorState() async {
        let recorder = Recorder()
        let model = AuthenticatorMFAViewModel(
            service: StubService(disableTOTP: {
                recorder.disableCalls += 1
            })
        )
        model.sync(userId: "user-1", isEnabled: true)

        let didDisable = await model.disable()
        #expect(didDisable)
        #expect(recorder.disableCalls == 1)
        #expect(model.isEnabled == false)
        #expect(model.backupCodes.isEmpty)
    }

    @Test
    func authoritativeStatusReconcilesAfterAnOptimisticMutation() async {
        let model = AuthenticatorMFAViewModel(service: StubService())
        model.sync(userId: "user-1", isEnabled: true)

        let didDisable = await model.disable()
        #expect(didDisable)
        #expect(model.isEnabled == false)

        model.sync(userId: "user-1", isEnabled: true)

        #expect(model.isEnabled)
    }

    @Test
    func authoritativeStatusUpdatesDuringSetup() async {
        let model = AuthenticatorMFAViewModel(service: StubService())
        model.sync(userId: "user-1", isEnabled: false)
        let didStart = await model.startSetup()
        #expect(didStart)

        model.sync(userId: "user-1", isEnabled: true)

        #expect(model.isEnabled)
        #expect(model.setupDetails != nil)
    }

    @Test
    func accountChangesClearSensitiveSetupData() async {
        let model = AuthenticatorMFAViewModel(
            service: StubService(
                createTOTP: {
                    AuthenticatorMFASetupDetails(secret: "SECRET", uri: "otpauth://totp/example")
                }
            )
        )
        model.sync(userId: "user-1", isEnabled: false)
        let didStart = await model.startSetup()
        #expect(didStart)
        model.verificationCode = "123456"

        model.sync(userId: "user-2", isEnabled: true)

        #expect(model.setupDetails == nil)
        #expect(model.verificationCode.isEmpty)
        #expect(model.backupCodes.isEmpty)
        #expect(model.isEnabled)
    }

    @Test
    func accountChangesDiscardAnInFlightVerification() async {
        let verificationStarted = AsyncStream<Void>.makeStream()
        let resumeVerification = AsyncStream<Void>.makeStream()
        let model = AuthenticatorMFAViewModel(
            service: StubService(
                verifyTOTP: { _ in
                    verificationStarted.continuation.yield()
                    for await _ in resumeVerification.stream {
                        break
                    }
                    return ["old-account-code"]
                }
            )
        )
        model.sync(userId: "user-1", isEnabled: false)
        model.verificationCode = "123456"

        let verificationTask = Task {
            await model.verifySetup()
        }
        for await _ in verificationStarted.stream {
            break
        }

        model.sync(userId: "user-2", isEnabled: false)
        resumeVerification.continuation.yield()
        let didVerify = await verificationTask.value

        #expect(didVerify == false)
        #expect(model.backupCodes.isEmpty)
        #expect(model.isEnabled == false)
        #expect(model.errorMessage == nil)
    }

    @Test
    func cancellationDiscardsAnInFlightVerification() async {
        let verificationStarted = AsyncStream<Void>.makeStream()
        let resumeVerification = AsyncStream<Void>.makeStream()
        let model = AuthenticatorMFAViewModel(
            service: StubService(
                verifyTOTP: { _ in
                    verificationStarted.continuation.yield()
                    for await _ in resumeVerification.stream {
                        break
                    }
                    return ["stale-code"]
                }
            )
        )
        model.sync(userId: "user-1", isEnabled: false)
        model.verificationCode = "123456"

        let verificationTask = Task {
            await model.verifySetup()
        }
        for await _ in verificationStarted.stream {
            break
        }

        verificationTask.cancel()
        resumeVerification.continuation.yield()
        let didVerify = await verificationTask.value

        #expect(didVerify == false)
        #expect(model.backupCodes.isEmpty)
        #expect(model.isEnabled == false)
        #expect(model.errorMessage == nil)
    }

    @Test
    func backupCodeTextMatchesTheWebExportFormat() {
        #expect(
            BackupCodesFile.contents(for: ["alpha", "bravo"])
                == "Tinfoil backup codes\n\nalpha\nbravo\n"
        )
    }

    @Test
    func backupCodeExportsUseAnIsolatedDirectory() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let url = try BackupCodesFile.write(
            codes: ["alpha", "bravo"],
            directory: temporaryDirectory
        )

        #expect(url.lastPathComponent == Constants.Security.backupCodesFilename)
        #expect(url.deletingLastPathComponent() != temporaryDirectory)
        #expect(try String(contentsOf: url, encoding: .utf8)
            == "Tinfoil backup codes\n\nalpha\nbravo\n")
    }
}

@MainActor
private final class Recorder {
    var verificationCodes: [String] = []
    var disableCalls = 0
}

@MainActor
private struct StubService: AuthenticatorMFAService {
    var createTOTPHandler: () async throws -> AuthenticatorMFASetupDetails = {
        AuthenticatorMFASetupDetails(secret: "SECRET", uri: "otpauth://totp/example")
    }
    var verifyTOTPHandler: (String) async throws -> [String] = { _ in [] }
    var disableTOTPHandler: () async throws -> Void = {}

    init(
        createTOTP: @escaping () async throws -> AuthenticatorMFASetupDetails = {
            AuthenticatorMFASetupDetails(secret: "SECRET", uri: "otpauth://totp/example")
        },
        verifyTOTP: @escaping (String) async throws -> [String] = { _ in [] },
        disableTOTP: @escaping () async throws -> Void = {}
    ) {
        createTOTPHandler = createTOTP
        verifyTOTPHandler = verifyTOTP
        disableTOTPHandler = disableTOTP
    }

    func createTOTP() async throws -> AuthenticatorMFASetupDetails {
        try await createTOTPHandler()
    }

    func verifyTOTP(code: String) async throws -> [String] {
        try await verifyTOTPHandler(code)
    }

    func disableTOTP() async throws {
        try await disableTOTPHandler()
    }
}
