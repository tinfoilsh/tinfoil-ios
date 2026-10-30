import Foundation
import Testing
@testable import TinfoilChat

@Suite("Link opener")
struct LinkOpenerTests {
    @Test(arguments: ["https://tinfoil.sh/a?b=c", "HTTP://example.com", "mailto:a@example.com"])
    func opensWebPagesAndMail(_ link: String) throws {
        #expect(LinkOpener.canOpen(try #require(URL(string: link))))
    }

    @Test(arguments: ["tel:5551234", "shortcuts://run-shortcut?name=x", "javascript:alert(1)", "file:///etc/hosts", "tinfoil://open"])
    func opensNothingThatActsInAnotherApp(_ link: String) throws {
        #expect(!LinkOpener.canOpen(try #require(URL(string: link))))
    }
}
