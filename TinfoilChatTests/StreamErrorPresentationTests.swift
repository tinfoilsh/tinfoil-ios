import Foundation
import Testing
@testable import TinfoilChat

@Suite("Stream error presentation")
struct StreamErrorPresentationTests {
    private static func error(_ code: String, _ action: ErrorAction, kind: String? = nil, retryAfter: Int? = nil, resetsAt: String? = nil, upstreamCode: String? = nil) -> HarnessErrorBody {
        HarnessErrorBody(code: code, message: "service detail", action: action, kind: kind, retryAfter: retryAfter, resetsAt: resetsAt, upstreamCode: upstreamCode)
    }

    @Test func aBusyServiceIsResentOnceItsWaitHasPassed() {
        let shown = StreamErrorPresentation(Self.error(HarnessErrorCode.rateLimited, .retry, retryAfter: 7), occurredAt: nil)
        #expect(shown.kind == .busy)
        #expect(shown.offersRetry && shown.resends)
        #expect(shown.retryAfter == 7)
    }

    @Test func anExhaustedQuotaOffersNoRetryAndOnlyTheFreeDailyOneAnUpgrade() {
        let resetsAt = "2026-10-28T15:00:00Z"
        let hourly = StreamErrorPresentation(Self.error(HarnessErrorCode.quotaExhausted, .wait, kind: "hourly", resetsAt: resetsAt), occurredAt: nil)
        #expect(hourly.kind == .rateLimit && !hourly.offersRetry && !hourly.offersUpgrade)
        let time = ChatAccessCache.date(of: resetsAt)!.formatted(date: .omitted, time: .shortened)
        #expect(hourly.suggestion.contains(time))
        let daily = StreamErrorPresentation(Self.error(HarnessErrorCode.quotaExhausted, .wait, kind: "free_daily"), occurredAt: nil)
        #expect(daily.offersUpgrade && !daily.offersRetry)
    }

    @Test func aKeyThisDeviceMustUnlockOffersUnlockNotRetry() {
        let shown = StreamErrorPresentation(Self.error(HarnessErrorCode.keyMismatch, .unlock), occurredAt: nil)
        #expect(shown.kind == .key && shown.offersUnlock && !shown.offersRetry)
    }

    @Test func aCodeThisClientDoesNotKnowIsExplainedByItsAction() {
        let revise = StreamErrorPresentation(Self.error("LATER_CODE", .revise), occurredAt: nil)
        #expect(revise.kind == .revise && !revise.offersRetry)
        let stop = StreamErrorPresentation(Self.error("LATER_CODE", .stop), occurredAt: nil)
        #expect(stop.kind == .refused && !stop.offersRetry)
        let retry = StreamErrorPresentation(Self.error("LATER_CODE", .retry), occurredAt: nil)
        #expect(retry.kind == .server && retry.offersRetry && !retry.resends)
    }

    @Test func aDroppedStreamIsAConnectionProblemThatResends() {
        let shown = StreamErrorPresentation(Self.error(HarnessErrorCode.streamInterrupted, .retry), occurredAt: nil)
        #expect(shown.kind == .connection && shown.resends)
    }

    @Test func aDocumentThatFailedToConvertShowsTheConvertersExplanation() {
        let shown = StreamErrorPresentation(Self.error(HarnessErrorCode.upstreamRefused, .revise, upstreamCode: "document_unreadable"), occurredAt: nil)
        #expect(shown.kind == .document)
        #expect(shown.suggestion == "service detail")
    }
}
