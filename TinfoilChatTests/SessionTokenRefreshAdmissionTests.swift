import Testing
@testable import TinfoilChat

struct SessionTokenRefreshAdmissionTests {
    @Test
    func concurrentRefreshesAreRejectedUntilTheOwnerFinishes() throws {
        var admission = SessionTokenRefreshAdmission()
        let firstAdmission = admission.begin()
        let first = try #require(firstAdmission)
        let rejected = admission.begin()
        #expect(rejected == nil)
        admission.finish(first)
        let nextAdmission = admission.begin()
        let next = try #require(nextAdmission)
        #expect(next != first)
    }

    @Test
    func invalidationAdmitsANewRefreshWithoutWaitingForThePreviousOwner() throws {
        var admission = SessionTokenRefreshAdmission()
        let oldAdmission = admission.begin()
        let old = try #require(oldAdmission)
        admission.reset()
        let currentAdmission = admission.begin()
        let current = try #require(currentAdmission)
        #expect(current != old)
        admission.finish(old)
        #expect(admission.requestID == current)
        let rejected = admission.begin()
        #expect(rejected == nil)
        admission.finish(current)
        let admitted2 = admission.begin()
        #expect(admitted2 != nil)
    }

    @Test
    func invalidationRetiresAnOwnerThatHasNotStartedItsWork() throws {
        var admission = SessionTokenRefreshAdmission()
        let queuedAdmission = admission.begin()
        let queued = try #require(queuedAdmission)
        admission.reset()
        #expect(admission.requestID != queued)
        admission.finish(queued)
        #expect(admission.requestID == nil)
    }
}
