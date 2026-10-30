import EHBP
import Foundation
import Testing
@testable import Tinfoil
@testable import TinfoilChat

@Suite("Sealed transport errors")
struct SealedTransportTests {
    private static func mapped(_ error: any Error) -> HarnessError? {
        SealedTransport.harnessError(for: error) as? HarnessError
    }

    @Test(arguments: [
        TinfoilError.network("attestation fetch failed", urlError: URLError(.notConnectedToInternet)),
        URLError(.notConnectedToInternet),
        URLError(.timedOut),
    ] as [any Error])
    func aChatServiceThatCouldNotBeReachedIsAConnectionProblemToRetry(_ failure: any Error) {
        let error = Self.mapped(failure)
        #expect(error == HarnessError(HarnessErrorBody.unreachable))
        #expect(error?.code == HarnessErrorCode.connection && error?.action == .retry)
    }

    @Test func anEnclaveThatFailedVerificationSaysNothingWasSent() {
        let error = Self.mapped(TinfoilError.attestation("quote: bad signature", layer: .quote))
        #expect(error?.code == HarnessErrorCode.attestation)
        #expect(error?.action == .retry)
        #expect(error?.detail.message == "The chat service could not be verified, so nothing was sent.")
    }

    @Test func aRequestTheSDKRefusesToSendStops() {
        let error = Self.mapped(TinfoilError.configuration("refusing redirect to https://elsewhere.example"))
        #expect(error?.code == HarnessErrorCode.configuration)
        #expect(error?.action == .stop)
    }

    @Test(arguments: [
        EHBPError(.keyConfigMismatch, "EHBP key configuration still mismatched after refresh"),
        EHBPError(.missingResponseNonce, "missing Ehbp-Response-Nonce header"),
        EHBPError(.invalidResponseNonce, "invalid response nonce hex"),
        EHBPError(.aeadDecryptFailed, "decryption failed"),
    ])
    func anAnswerNotSealedToTheRequestIsRefusedAsUnsealed(_ failure: EHBPError) {
        #expect(Self.mapped(failure) == HarnessError(HarnessErrorBody.unsealedAnswer))
    }

    @Test(arguments: [URLError(.cancelled), CancellationError()] as [any Error])
    func aCancelledRequestFailsAsCancelled(_ failure: any Error) {
        #expect(SealedTransport.harnessError(for: failure) is CancellationError)
    }
}
