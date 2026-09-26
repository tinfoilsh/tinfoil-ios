import Testing
@testable import TinfoilChat

struct SessionTokenRefreshAdmissionTests {
    @Test
    func concurrentRefreshesAreRejectedUntilTheOwnerFinishes() throws {
        var admission = SessionTokenRefreshAdmission()
        let first = try #require(admission.begin())
        #expect(admission.begin() == nil)
        admission.finish(first)
        let next = try #require(admission.begin())
        #expect(next != first)
    }

    @Test
    func invalidationAdmitsANewRefreshWithoutWaitingForThePreviousOwner() throws {
        var admission = SessionTokenRefreshAdmission()
        let old = try #require(admission.begin())
        admission.reset()
        let current = try #require(admission.begin())
        #expect(current != old)
        admission.finish(old)
        #expect(admission.requestID == current)
        #expect(admission.begin() == nil)
        admission.finish(current)
        #expect(admission.begin() != nil)
    }

    @Test
    func invalidationRetiresAnOwnerThatHasNotStartedItsWork() throws {
        var admission = SessionTokenRefreshAdmission()
        let queued = try #require(admission.begin())
        admission.reset()
        #expect(admission.requestID != queued)
        admission.finish(queued)
        #expect(admission.requestID == nil)
    }
}
