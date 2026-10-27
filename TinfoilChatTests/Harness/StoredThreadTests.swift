import Foundation
import Testing
@testable import TinfoilChat

@Suite("Stored threads")
struct StoredThreadTests {
    private static let record: [String: Any] = [
        "id": "t", "title": "Cats", "titleState": "generated", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z",
        "model": "gpt-oss-120b", "projectId": NSNull(), "presetId": "user:p", "pinned": false, "webSearchEnabled": false,
        "recordVersion": 3, "aLaterMember": ["kept": true],
        "messages": [
            ["id": "u", "role": "user", "createdAt": "2026-01-01T00:00:10Z", "content": "Look",
             "attachments": [
                ["id": "img", "kind": "image", "fileName": "cat.png", "mimeType": "image/png", "base64": "QUJD", "thumbnail": "QQ=="],
                ["id": "doc", "kind": "document", "fileName": "notes.pdf", "mimeType": "application/pdf",
                 "pages": [["text": "page one", "image": "UEFHRTE=", "page": 1, "is_scanned": true], ["text": "page two", "image": "", "page": 2, "is_scanned": false]]],
             ]],
            ["id": "a", "role": "assistant", "createdAt": "2026-01-01T00:00:20Z", "content": "A cat.", "laterMessageMember": 7],
        ],
    ]

    @Test func keepsEveryMemberItWasGivenAndWritesThemBack() throws {
        let thread = try #require(StoredThread(json: Self.record))
        let written = try JSONSerialization.jsonObject(with: thread.data()) as! NSDictionary
        #expect(written == NSDictionary(dictionary: Self.record))
        #expect(thread.id == "t")
        #expect(thread.title == "Cats")
        #expect(thread.titleState == .generated)
        #expect(thread.recordVersion == 3)
        #expect(!thread.webSearchEnabled)
        #expect(thread.presetId == "user:p")
    }

    @Test func aRecordWithoutMessagesIsNotAThread() {
        #expect(StoredThread(json: ["id": "t"]) == nil)
    }

    @Test func numbersAndBooleansSurviveARoundTripThroughRawJSON() throws {
        let text = #"{"flag":true,"off":false,"one":1,"zero":0,"big":9007199254740993,"ratio":0.5}"#
        let raw = try JSONDecoder().decode(RawJSON.self, from: Data(text.utf8))
        let written = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        for member in [#""flag":true"#, #""off":false"#, #""one":1"#, #""zero":0"#, #""big":9007199254740993"#, #""ratio":0.5"#] {
            #expect(written.contains(member), "\(written) lacks \(member)")
        }
        // Values this client builds itself encode the same way.
        let built = String(decoding: try JSONEncoder().encode(AnyJSON(["flag": true, "one": 1, "ratio": 0.5] as [String: Any])), as: UTF8.self)
        for member in [#""flag":true"#, #""one":1"#, #""ratio":0.5"#] {
            #expect(built.contains(member), "\(built) lacks \(member)")
        }
    }

    @Test func theSummaryAndWindowLeaveOutTheBytesTheDeviceHolds() throws {
        let thread = try #require(StoredThread(json: Self.record))
        let summary = thread.summary
        #expect(summary.messageCount == 2)
        #expect(summary.activityAt == "2026-01-01T00:00:20.000Z")
        #expect(summary.projectId == nil)
        #expect(!summary.pinned)
        let window = thread.window
        #expect(window.messages.map(\.id) == ["u", "a"])
        let attachments = try #require(window.messages.first?.attachments)
        #expect(attachments.map(\.id) == ["img", "doc"])
        #expect(attachments.first?.thumbnail == "QQ==")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as! [String: Any]
        let shown = (encoded["messages"] as! [[String: Any]])[0]["attachments"] as! [[String: Any]]
        #expect(shown[0]["base64"] == nil)
        #expect(shown[1]["pages"] == nil)
        #expect(shown[1]["fileName"] as? String == "notes.pdf")
    }

    @Test func heldImagesAreRestoredWhereTheHarnessLeftThemOut() throws {
        let thread = try #require(StoredThread(json: Self.record))
        let held = thread.heldImages
        #expect(held["img"] == HeldImages(base64: "QUJD", pageImages: nil))
        #expect(held["doc"] == HeldImages(base64: nil, pageImages: ["UEFHRTE=", ""]))
        var returned = try #require(StoredThread(json: Self.record))
        returned.messages = returned.messages.map { message in
            var object = message.objectValue!
            object["attachments"] = .array((object["attachments"]?.arrayValue ?? []).map { attachment in
                var fields = attachment.objectValue!
                fields["base64"] = nil
                fields["pages"] = fields["pages"]?.arrayValue.map { pages in .array(pages.map { page in
                    var page = page.objectValue!
                    page["image"] = nil
                    return .object(page)
                }) }
                return .object(fields)
            })
            return .object(object)
        }
        #expect(returned.heldImages.isEmpty)
        returned.restore(held)
        #expect(returned.heldImages == held)
    }

    @Test func aShareCarriesDocumentTextAndNoBytes() throws {
        let thread = try #require(StoredThread(json: Self.record))
        let shared = thread.forShare()
        let attachments = shared.messages[0].objectValue!["attachments"]!.arrayValue!.map { $0.objectValue! }
        #expect(attachments[0]["base64"] == nil)
        #expect(attachments[0]["thumbnail"]?.stringValue == "QQ==")
        #expect(attachments[1]["pages"] == nil)
        #expect(attachments[1]["textContent"]?.stringValue == "page one\n\npage two")
    }

    @Test func userSettingsAreTakenFromAnotherCopy() throws {
        let before = try #require(StoredThread(json: Self.record))
        var after = before
        after["title"] = .string("Dogs")
        after["model"] = .string("auto")
        after["messages"] = .array([])
        #expect(after.changedSettings(from: before) == ["title", "model"])
        var kept = before
        kept.take(["title", "messages"], from: after)
        #expect(kept.title == "Dogs")
        #expect(kept.model == "gpt-oss-120b")
        #expect(kept.messages.count == 2)
    }

    @Test func aNewChatListsUnderThePlaceholderTitle() {
        let thread = StoredThread.new(id: "n", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(thread.title == Constants.Harness.placeholderTitle)
        #expect(thread.titleState == .placeholder)
        #expect(thread.messages.isEmpty)
        #expect(thread.summary.activityAt == "2023-11-14T22:13:20.000Z")
        #expect(thread.recordVersion == nil)
    }
}

@Suite("Device thread store")
struct DeviceThreadStoreTests {
    private func thread(_ id: String, at: String) -> StoredThread {
        StoredThread(json: ["id": id, "title": id, "titleState": "generated", "createdAt": at, "model": "auto", "messages": [
            ["id": "\(id)-m", "role": "user", "createdAt": at, "content": "hi", "attachments": [["id": "\(id)-img", "kind": "image", "fileName": "c.png", "mimeType": "image/png"]]],
        ]])!
    }

    @Test func listsUpdatesAndDeletesChats() async throws {
        let store = DeviceThreadStore(directory: nil)
        _ = try await store.add(thread("a", at: "2026-01-01T00:00:00Z"))
        _ = try await store.add(thread("b", at: "2026-01-02T00:00:00Z"))
        // Chats active at the same time list by id, the later first.
        _ = try await store.add(thread("c", at: "2026-01-01T00:00:00Z"))
        #expect(try await store.list().map(\.id) == ["b", "c", "a"])
        #expect(try await store.add(thread("a", at: "2026-01-03T00:00:00Z")) == nil)
        let updated = try await store.update("a") { current in
            var next = current!
            next["title"] = .string("Renamed")
            return next
        }
        #expect(updated?.title == "Renamed")
        #expect(try await store.get("a")?.title == "Renamed")
        #expect(try await store.list().first { $0.id == "a" }?.title == "Renamed")
        let skipped = try await store.update("a") { _ in nil }
        #expect(skipped == nil)
        try await store.delete("a")
        #expect(try await store.get("a") == nil)
        #expect(try await store.list().map(\.id) == ["b", "c"])
        #expect(try await store.deleteAll() == 2)
        #expect(try await store.list().isEmpty)
    }

    @Test func overlappingUpdatesOfOneChatKeepEachOthersChanges() async throws {
        let store = DeviceThreadStore(directory: nil)
        _ = try await store.add(thread("a", at: "2026-01-01T00:00:00Z"))
        // Each update appends a message to what it reads; a lost update
        // would leave fewer than all of them.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = try? await store.update("a") { current in
                        var next = current!
                        next.messages.append(.object(["id": .string("m\(index)"), "role": .string("user"), "createdAt": .string("2026-01-01T00:00:00Z"), "content": .string("\(index)")]))
                        return next
                    }
                }
            }
        }
        #expect(try await store.get("a")?.messages.count == 9)
        #expect(try await store.list().first?.messageCount == 9)
    }

    @Test func originalsFollowTheAttachmentsThatRemain() async throws {
        let store = DeviceThreadStore(directory: nil)
        let original = AttachmentOriginal(base64: "T1JJRw==", mimeType: "image/png")
        _ = try await store.add(thread("a", at: "2026-01-01T00:00:00Z"), originals: ["a-img": original, "gone": original])
        #expect(try await store.originals("a", attachmentIds: ["a-img", "gone"]) == ["a-img": original])
        _ = try await store.update("a") { current in
            var next = current!
            next.messages = []
            return next
        }
        #expect(try await store.originals("a", attachmentIds: ["a-img"]).isEmpty)
    }

    @Test func anUpdateOfAChatNotStoredStartsFromNothing() async throws {
        let store = DeviceThreadStore(directory: nil)
        let made = try await store.update("new") { current in
            #expect(current == nil)
            return StoredThread.new(id: "new")
        }
        #expect(made?.id == "new")
        #expect(try await store.list().map(\.id) == ["new"])
    }
}
