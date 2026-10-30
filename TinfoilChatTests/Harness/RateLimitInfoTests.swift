import Foundation
import Testing
@testable import TinfoilChat

struct RateLimitInfoTests {
    @Test func anHourlyPlanThatBudgetsTokensIsNotExhausted() {
        let minted = HarnessRateLimit(kind: .named(.hourly), inputTokens: .init(max: 1000, used: 10, remaining: 990))
        let info = RateLimitInfo(minted)
        #expect(info?.kind == .hourly)
        #expect(info?.exhausted == false)
    }

    @Test func aQuotaWithNoRequestsLeftIsExhausted() {
        #expect(RateLimitInfo(HarnessRateLimit(kind: .named(.hourly), maxRequests: 0, remaining: 0))?.exhausted == true)
        #expect(RateLimitInfo(HarnessRateLimit(kind: .named(.freeDaily), maxRequests: 20, remaining: 0))?.exhausted == true)
        #expect(RateLimitInfo(HarnessRateLimit(kind: .named(.freeDaily), maxRequests: 20, remaining: 3))?.exhausted == false)
    }

    @Test func aQuotaOfAKindThisClientDoesNotKnowIsNotShown() throws {
        let limit = try JSONDecoder().decode(HarnessRateLimit.self, from: Data(#"{"kind":"weekly","maxRequests":20,"remaining":3}"#.utf8))
        #expect(RateLimitInfo(limit) == nil)
        #expect(RateLimitInfo(HarnessRateLimit(kind: nil)) == nil)
    }
}
