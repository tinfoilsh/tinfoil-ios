import ClerkKit
import Combine
import Foundation

struct AuthenticatorMFASetupDetails: Equatable {
    let secret: String
    let uri: String
}

@MainActor
protocol AuthenticatorMFAService {
    func createTOTP() async throws -> AuthenticatorMFASetupDetails
    func verifyTOTP(code: String) async throws -> [String]
    func disableTOTP() async throws
}

@MainActor
struct ClerkAuthenticatorMFAService: AuthenticatorMFAService {
    func createTOTP() async throws -> AuthenticatorMFASetupDetails {
        let (user, userId) = try currentUser()
        let resource = try await user.createTOTP()
        try ensureCurrentUser(userId)

        guard let secret = resource.secret, let uri = resource.uri else {
            throw AuthenticatorMFAError.missingSetupDetails
        }
        return AuthenticatorMFASetupDetails(secret: secret, uri: uri)
    }

    func verifyTOTP(code: String) async throws -> [String] {
        let (user, userId) = try currentUser()
        let resource = try await user.verifyTOTP(code: code)
        try ensureCurrentUser(userId)

        guard resource.verified else {
            throw AuthenticatorMFAError.verificationFailed
        }
        await reloadCurrentUser(userId: userId)
        try ensureCurrentUser(userId)
        return resource.backupCodes ?? []
    }

    func disableTOTP() async throws {
        let (user, userId) = try currentUser()
        try await user.disableTOTP()
        try ensureCurrentUser(userId)
        await reloadCurrentUser(userId: userId)
        try ensureCurrentUser(userId)
    }

    private func currentUser() throws -> (User, String) {
        guard let user = Clerk.shared.user else {
            throw AuthenticatorMFAError.missingSession
        }
        return (user, user.id)
    }

    private func ensureCurrentUser(_ userId: String) throws {
        guard Clerk.shared.user?.id == userId else {
            throw AuthenticatorMFAError.accountChanged
        }
    }

    private func reloadCurrentUser(userId: String) async {
        guard Clerk.shared.user?.id == userId else { return }
        try? await Clerk.shared.user?.reload()
    }
}

enum AuthenticatorMFAError: LocalizedError {
    case accountChanged
    case missingSession
    case missingSetupDetails
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .accountChanged:
            "Your account changed during this request. Please try again."
        case .missingSession:
            "Your account session is unavailable. Please sign in again."
        case .missingSetupDetails:
            "The authenticator setup details were unavailable. Please try again."
        case .verificationFailed:
            "That code could not be verified. Please try again."
        }
    }
}

@MainActor
final class AuthenticatorMFAViewModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var setupDetails: AuthenticatorMFASetupDetails?
    @Published private(set) var backupCodes: [String] = []
    @Published private(set) var isWorking = false
    @Published private(set) var reverificationLevel: SessionVerification.Level?
    @Published var verificationCode = ""
    @Published var errorMessage: String?

    private let service: any AuthenticatorMFAService
    private var userId: String?
    private var userRevision = 0

    init(service: (any AuthenticatorMFAService)? = nil) {
        self.service = service ?? ClerkAuthenticatorMFAService()
    }

    var canVerify: Bool {
        verificationCode.count == Constants.Security.totpCodeLength
            && verificationCode.allSatisfy(Constants.Security.asciiDigits.contains)
            && !isWorking
    }

    func sync(userId: String?, isEnabled: Bool) {
        guard self.userId != userId else {
            if self.isEnabled != isEnabled {
                self.isEnabled = isEnabled
            }
            return
        }

        self.userId = userId
        userRevision += 1
        self.isEnabled = isEnabled
        clearSetupState()
        backupCodes = []
        errorMessage = nil
        reverificationLevel = nil
    }

    @discardableResult
    func startSetup() async -> Bool {
        await perform(
            reverificationFallback: .firstFactor,
            operation: service.createTOTP
        ) { details in
            setupDetails = details
            verificationCode = ""
            backupCodes = []
        }
    }

    @discardableResult
    func verifySetup() async -> Bool {
        guard canVerify else { return false }
        let code = verificationCode
        return await perform(
            operation: { try await service.verifyTOTP(code: code) }
        ) { codes in
            backupCodes = codes
            isEnabled = true
            clearSetupState()
        }
    }

    @discardableResult
    func disable() async -> Bool {
        await perform(
            reverificationFallback: .multiFactor,
            operation: service.disableTOTP
        ) {
            isEnabled = false
            clearSetupState()
            backupCodes = []
        }
    }

    func cancelSetup() {
        clearSetupState()
        errorMessage = nil
    }

    func dismissBackupCodes() {
        backupCodes = []
    }

    func clearReverificationRequest() {
        reverificationLevel = nil
    }

    private func clearSetupState() {
        setupDetails = nil
        verificationCode = ""
    }

    private func perform<Value>(
        reverificationFallback: SessionVerification.Level? = nil,
        operation: () async throws -> Value,
        apply: (Value) -> Void
    ) async -> Bool {
        guard !isWorking else { return false }
        let operationRevision = userRevision
        isWorking = true
        errorMessage = nil
        reverificationLevel = nil
        defer { isWorking = false }

        do {
            let value = try await operation()
            guard operationRevision == userRevision, !Task.isCancelled else { return false }
            apply(value)
            return true
        } catch {
            guard operationRevision == userRevision, !Task.isCancelled else { return false }
            if let reverificationFallback,
               let level = Self.reverificationLevel(for: error, fallback: reverificationFallback) {
                reverificationLevel = level
            } else {
                errorMessage = Self.message(for: error)
            }
            return false
        }
    }

    private static func reverificationLevel(
        for error: Error,
        fallback: SessionVerification.Level
    ) -> SessionVerification.Level? {
        guard let clerkError = error as? ClerkAPIError,
              clerkError.code == Constants.Security.reverificationRequiredErrorCode else {
            return nil
        }
        if let reverificationType = clerkError.meta?[
            Constants.Security.reverificationMetadataKey
        ]?.stringValue {
            if Constants.Security.multiFactorReverificationTypes.contains(reverificationType) {
                return .multiFactor
            }
            if Constants.Security.secondFactorReverificationTypes.contains(reverificationType) {
                return .secondFactor
            }
        }
        guard let rawLevel = clerkError.meta?[
            keyPath: Constants.Security.reverificationLevelMetadataKeyPath
        ]?.stringValue else {
            return fallback
        }
        let level = SessionVerification.Level(rawValue: rawLevel)
        if case .unknown = level {
            return fallback
        }
        return level
    }

    static func message(for error: Error) -> String {
        if let clerkError = error as? ClerkAPIError {
            return clerkError.longMessage ?? clerkError.message ?? Constants.Security.errorMessage
        }
        if let clerkError = error as? any ClerkError, let message = clerkError.message {
            return message
        }
        let description = error.localizedDescription
        return description.isEmpty ? Constants.Security.errorMessage : description
    }
}

enum BackupCodesFile {
    static func contents(for codes: [String]) -> String {
        ([Constants.Security.backupCodesTitle, ""] + codes + [""]).joined(separator: "\n")
    }

    static func write(codes: [String], directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let exportDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var didFinish = false
        defer {
            if !didFinish {
                try? FileManager.default.removeItem(at: exportDirectory)
            }
        }
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: false
        )
        let url = exportDirectory.appendingPathComponent(Constants.Security.backupCodesFilename)
        try contents(for: codes).write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        didFinish = true
        return url
    }
}
