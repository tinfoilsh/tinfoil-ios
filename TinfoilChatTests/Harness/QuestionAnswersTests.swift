import Foundation
import Testing
@testable import TinfoilChat

@Suite("Question answers")
struct QuestionAnswersTests {
    private static let arguments = #"""
    {"title":"Quiz","questions":[
      {"id":"q1","prompt":"Capital of France?","selection":"single","options":[{"id":"a","label":"Lyon"},{"id":"b","label":"Paris"}]},
      {"id":"q2","prompt":"Pick the primes","selection":"multiple","options":[{"id":"x","label":"2"},{"id":"y","label":"3"},{"id":"z","label":"4"}]}
    ]}
    """#

    private static func reply(answers: QuestionAnswers? = nil) throws -> HarnessMessage {
        var block: [String: Any] = ["id": "q", "type": "tool_call", "toolCallId": "q", "name": QuestionSet.widgetName, "arguments": arguments, "complete": true]
        if let answers { block["answers"] = answers }
        return try HarnessMessage(jsonObject: ["id": "a1", "role": "assistant", "createdAt": "2026-01-01T00:00:00Z", "timeline": [block]])
    }

    /// A question that sent the widget's answers: q1 with the options given,
    /// and q2 unanswered.
    private static func question(id: String, sentQ1 options: [(id: String, label: String)]) throws -> HarnessMessage {
        try HarnessMessage(jsonObject: [
            "id": id, "role": "user", "createdAt": "2026-01-01T00:00:01Z", "content": "",
            "answers": [["toolCallId": "q", "title": "Quiz", "questions": [
                ["id": "q1", "prompt": "Capital of France?", "answered": true, "selected": options.map { ["id": $0.id, "label": $0.label] }],
                ["id": "q2", "prompt": "Pick the primes", "answered": false, "selected": []],
            ]]],
        ])
    }

    @Test func answersNoMessageSentReachTheModelWithTheNextMessage() throws {
        let unanswered = try Self.reply()
        #expect(QuestionAnswering.unsent(in: [unanswered], changes: [:]).isEmpty)
        #expect(!QuestionAnswering.isUnsent("q", answers: [:], in: [unanswered]))

        let answered = try Self.reply(answers: ["q1": ["b"]])
        let unsent = QuestionAnswering.unsent(in: [answered], changes: [:])
        #expect(unsent.map(\.toolCallId) == ["q"])
        #expect(unsent.first?.title == "Quiz")
        #expect(unsent.first?.questions.map(\.answered) == [true, false])
        #expect(unsent.first?.questions.first?.selected.map(\.label) == ["Paris"])
        #expect(QuestionAnswering.isUnsent("q", answers: ["q1": ["b"]], in: [answered]))
    }

    @Test func answersAMessageSentAreNotSentAgainUntilTheyChange() throws {
        let messages = try [Self.reply(answers: ["q1": ["b"]]), Self.question(id: "u1", sentQ1: [("b", "Paris")])]
        #expect(QuestionAnswering.unsent(in: messages, changes: [:]).isEmpty)
        #expect(!QuestionAnswering.isUnsent("q", answers: ["q1": ["b"]], in: messages))
        #expect(QuestionAnswering.isUnsent("q", answers: ["q1": ["a"]], in: messages))
        #expect(QuestionAnswering.isUnsent("q", answers: [:], in: messages))

        // The latest message to send a widget's answers is the one that counts.
        let resent = try messages + [Self.question(id: "u2", sentQ1: [("a", "Lyon")])]
        #expect(QuestionAnswering.isUnsent("q", answers: ["q1": ["b"]], in: resent))
        #expect(!QuestionAnswering.isUnsent("q", answers: ["q1": ["a"]], in: resent))
    }

    @Test func changesNotSavedYetAreSentWithTheOptionsInTheOrderOffered() throws {
        let messages = try [Self.reply(answers: ["q1": ["b"]]), Self.question(id: "u1", sentQ1: [("b", "Paris")])]
        let unsent = QuestionAnswering.unsent(in: messages, changes: ["q": ["q2": .value(["y", "x"]), "q1": .null]])
        let questions = try #require(unsent.first?.questions)
        #expect(questions.map(\.answered) == [false, true])
        #expect(questions.first?.selected.isEmpty == true)
        #expect(questions.last?.selected.map(\.label) == ["2", "3"])
    }

    @Test func questionsNeedIdsUsedOnce() throws {
        #expect(QuestionSet(arguments: Self.arguments)?.questions.count == 2)
        let repeatedQuestion = #"{"questions":[{"id":"q1","prompt":"A?","selection":"single","options":[{"id":"a","label":"A"}]},{"id":"q1","prompt":"B?","selection":"single","options":[{"id":"b","label":"B"}]}]}"#
        #expect(QuestionSet(arguments: repeatedQuestion) == nil)
        let repeatedOption = #"{"questions":[{"id":"q1","prompt":"A?","selection":"multiple","options":[{"id":"a","label":"A"},{"id":"a","label":"B"}]}]}"#
        #expect(QuestionSet(arguments: repeatedOption) == nil)
        let unknownSelection = #"{"questions":[{"id":"q1","prompt":"A?","selection":"ranked","options":[{"id":"a","label":"A"}]}]}"#
        #expect(QuestionSet(arguments: unknownSelection) == nil)
    }
}
