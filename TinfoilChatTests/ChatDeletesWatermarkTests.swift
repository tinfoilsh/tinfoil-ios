//
//  ChatDeletesWatermarkTests.swift
//  TinfoilChatTests
//

import Foundation
import Testing
@testable import TinfoilChat

struct ChatDeletesWatermarkTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "chat-deletes-watermark-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    @Test func loadDefaultsToEpochWhenUnsetOrCorrupt() {
        let defaults = makeDefaults()
        #expect(ChatDeletesWatermark.load(defaults: defaults) == ChatDeletesWatermark.epoch)

        defaults.set("not-a-timestamp", forKey: Constants.StorageKeys.Sync.chatDeletesWatermark)
        #expect(ChatDeletesWatermark.load(defaults: defaults) == ChatDeletesWatermark.epoch)
    }

    @Test func advanceSubtractsOverlapAndPersists() {
        let defaults = makeDefaults()
        let eventAt = formatter.date(from: "2026-01-01T00:00:20.000Z")!

        ChatDeletesWatermark.advance(latestEventAt: eventAt, defaults: defaults)

        let expected = eventAt.addingTimeInterval(-ChatDeletesWatermark.overlapSeconds)
        #expect(ChatDeletesWatermark.load(defaults: defaults) == formatter.string(from: expected))
    }

    @Test func advanceIsMonotonic() {
        let defaults = makeDefaults()
        let newer = formatter.date(from: "2026-01-01T00:01:00.000Z")!
        let older = formatter.date(from: "2026-01-01T00:00:30.000Z")!

        ChatDeletesWatermark.advance(latestEventAt: newer, defaults: defaults)
        let persisted = ChatDeletesWatermark.load(defaults: defaults)

        ChatDeletesWatermark.advance(latestEventAt: older, defaults: defaults)
        #expect(ChatDeletesWatermark.load(defaults: defaults) == persisted)
    }

    @Test func clearResetsToEpoch() {
        let defaults = makeDefaults()
        ChatDeletesWatermark.advance(
            latestEventAt: formatter.date(from: "2026-01-01T00:00:20.000Z")!,
            defaults: defaults
        )

        ChatDeletesWatermark.clear(defaults: defaults)

        #expect(ChatDeletesWatermark.load(defaults: defaults) == ChatDeletesWatermark.epoch)
    }
}
