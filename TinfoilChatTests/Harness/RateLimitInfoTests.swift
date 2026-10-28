import Testing
@testable import TinfoilChat

struct RateLimitInfoTests {
    @Test func anHourlyPlanThatBudgetsTokensIsNotExhausted() {
        let minted = HarnessRateLimit(kind: .hourly, inputTokens: .init(max: 1000, used: 10, remaining: 990))
        let info = RateLimitInfo(minted)
        #expect(info?.kind == .hourly)
        #expect(info?.exhausted == false)
    }

    @Test func aQuotaWithNoRequestsLeftIsExhausted() {
        #expect(RateLimitInfo(HarnessRateLimit(kind: .hourly, maxRequests: 0, remaining: 0))?.exhausted == true)
        #expect(RateLimitInfo(HarnessRateLimit(kind: .freeDaily, maxRequests: 20, remaining: 0))?.exhausted == true)
        #expect(RateLimitInfo(HarnessRateLimit(kind: .freeDaily, maxRequests: 20, remaining: 3))?.exhausted == false)
    }
}
