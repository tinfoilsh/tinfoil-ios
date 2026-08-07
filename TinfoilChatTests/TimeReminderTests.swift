//
//  TimeReminderTests.swift
//  TinfoilChatTests
//
//  Verifies the ephemeral current-time reminder: it is appended as the last
//  message only when requested, and its formatting has minute granularity so
//  retries within the same minute produce byte-identical requests, keeping
//  server-side prefix caching effective.
//

import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

struct TimeReminderTests {

    @Test @MainActor
    func appendsTimeReminderAsLastMessageWhenRequested() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "be helpful",
            rules: "",
            conversationMessages: [
                Message(role: .user, content: "hello")
            ],
            stream: false,
            genUIEnabled: false,
            includeTimeReminder: true
        )

        let messages = try encodedMessages(from: query)
        let last = try #require(messages.last)
        #expect(last["role"] as? String == "user")
        let content = try #require(last["content"] as? String)
        #expect(content.hasPrefix("<system-reminder>Current time: "))
        #expect(content.hasSuffix("</system-reminder>"))
        let secondToLast = messages[messages.count - 2]
        #expect(secondToLast["content"] as? String == "hello")
    }

    @Test @MainActor
    func omitsTimeReminderByDefault() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "be helpful",
            rules: "",
            conversationMessages: [
                Message(role: .user, content: "hello")
            ],
            stream: false,
            genUIEnabled: false
        )

        let messages = try encodedMessages(from: query)
        let hasReminder = messages.contains { message in
            (message["content"] as? String)?.contains("<system-reminder>") == true
        }
        #expect(!hasReminder)
    }

    @Test
    func formattingIsStableWithinTheSameMinute() {
        let base = Date(timeIntervalSince1970: 1_784_800_800)
        let first = TimeReminder.formatCurrentTimeReminder(now: base.addingTimeInterval(1))
        let second = TimeReminder.formatCurrentTimeReminder(now: base.addingTimeInterval(42))

        #expect(first == second)
    }

    private func encodedMessages(from query: ChatQuery) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(query)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["messages"] as? [[String: Any]] ?? []
    }
}
