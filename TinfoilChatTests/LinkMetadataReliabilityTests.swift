import Foundation
import Testing
@testable import TinfoilChat

struct LinkMetadataReliabilityTests {
    @Test func decodesLegacyAndFoundFaviconContracts() throws {
        let legacy = Data(#"{"favicon_bytes":"aWNvbg==","favicon_content_type":"image/x-icon"}"#.utf8)
        let found = Data(#"{"found":true,"favicon_bytes":"aWNvbg=="}"#.utf8)

        #expect(try LinkMetadataService.decodeFavicon(legacy) == Data("icon".utf8))
        #expect(try LinkMetadataService.decodeFavicon(found) == Data("icon".utf8))
    }

    @Test func cachesExplicitMissingFaviconContract() {
        let missing = Data(#"{"found":false,"status":"missing"}"#.utf8)
        #expect(throws: LinkMetadataError.faviconMissing) {
            try LinkMetadataService.decodeFavicon(missing)
        }
    }

    @Test func validatesMetadataURLAndAllowsLeanFallbacks() throws {
        let wrongURL = Data(#"{"url":"https://other.example","title":"Title"}"#.utf8)
        let lean = Data(#"{"url":"https://example.com","image":"javascript:alert(1)"}"#.utf8)

        #expect(throws: LinkMetadataError.invalidPayload) {
            try LinkMetadataService.decodeMetadata(wrongURL, requestedURL: "https://example.com")
        }
        let metadata = try LinkMetadataService.decodeMetadata(
            lean,
            requestedURL: "https://example.com"
        )
        #expect(metadata.title == nil)
        #expect(metadata.image == nil)
    }

    @Test func transientCooldownEscalatesAndCaps() {
        #expect(LinkMetadataService.transientCooldown(failureCount: 1) == 60)
        #expect(LinkMetadataService.transientCooldown(failureCount: 2) == 120)
        #expect(LinkMetadataService.transientCooldown(failureCount: 10) == 300)
    }
}
