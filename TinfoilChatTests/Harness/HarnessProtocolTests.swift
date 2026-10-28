import Foundation
import Testing
@testable import TinfoilChat

/// What this client names of the protocol by hand is held to the protocol's
/// copy at harness-protocol/openapi.yaml.
@Suite("Harness protocol")
struct HarnessProtocolTests {
    private static func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }

    @Test func namesEveryEventTheProtocolStreams() throws {
        let document = try HarnessProtocolFixtures.document
        let mapping = try Self.matches(##"^          ([A-Z_]+): "#/components/schemas/[A-Za-z]+Event"$"##, in: document)
        #expect(Set(mapping) == Set(HarnessEventType.allCases.map(\.rawValue)))
        #expect(mapping.count == HarnessEventType.allCases.count)
    }

    @Test func namesOnlyRoutesTheProtocolHas() throws {
        let document = try HarnessProtocolFixtures.document
        let paths = Set(try Self.matches(#"^  (/v1/[a-z/-]+):$"#, in: document))
        #expect(Set(HarnessRoute.allCases.map(\.rawValue)) == paths)
    }

    @Test func namesTheProtocolVersionItWasBuiltFrom() throws {
        let document = try HarnessProtocolFixtures.document
        let info = try Self.matches(#"^info:\n(?:  .*\n)*?  version: "(\d+)"$"#, in: document)
        #expect(info == [String(Constants.Harness.protocolVersion)])
    }

    @Test func actionsItDoesNotKnowStopTheRequest() {
        #expect(ErrorAction.of("reload") == .reload)
        #expect(ErrorAction.of("later_action") == .stop)
    }
}
