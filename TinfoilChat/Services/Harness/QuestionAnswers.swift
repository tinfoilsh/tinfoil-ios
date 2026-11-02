import Foundation

/// The options picked for each answered question of a questions widget, by
/// question id. A question it leaves out is unanswered.
typealias QuestionAnswers = [String: [String]]

/// Changes to a questions widget's answers, by question id: the options a
/// question takes, or null to leave it unanswered.
typealias AnswerChanges = [String: Nullable<[String]>]

/// How saving the answers picked in a questions widget goes.
enum AnswerSaveStatus: Equatable, Sendable {
    case saving
    /// The answers wait to be saved until the user tries again.
    case failed
}

/// A questions widget's arguments: the multiple-choice questions the model
/// asks, which the user answers in place.
struct QuestionSet: Decodable, Equatable {
    /// The widget the model asks its questions with.
    static let widgetName = "render_questions"

    enum Selection: String, Decodable {
        /// Exactly one option is the answer, as in a quiz.
        case single
        /// Any number of options may be picked, as in a checklist.
        case multiple
    }

    struct Option: Decodable, Equatable {
        let id: String
        let label: String
    }

    struct Question: Decodable, Equatable {
        let id: String
        let prompt: String
        let selection: Selection
        let options: [Option]
    }

    let title: String?
    let questions: [Question]

    private enum CodingKeys: String, CodingKey {
        case title, questions
    }
}

extension QuestionSet {
    /// The chat keeps answers by question and option ids, so a widget asks
    /// at least one question, offers each at least one option, and names
    /// each question, and each option of a question, once.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let questions = try container.decode([Question].self, forKey: .questions)
        let unique = Set(questions.map(\.id)).count == questions.count && questions.allSatisfy { question in
            !question.options.isEmpty && Set(question.options.map(\.id)).count == question.options.count
        }
        guard !questions.isEmpty, unique else {
            throw DecodingError.dataCorruptedError(forKey: .questions, in: container, debugDescription: "Questions need options and ids used once")
        }
        self.init(title: title, questions: questions)
    }

    /// A widget call's arguments, when they are a questions widget's.
    init?(arguments: String) {
        guard let data = arguments.data(using: .utf8), let questions = try? JSONDecoder().decode(QuestionSet.self, from: data) else { return nil }
        self = questions
    }

    /// The answers as a message sends them: every question with its text,
    /// and the options picked of those it offers, in the order offered.
    func sent(toolCallId: String, answers: QuestionAnswers) -> WidgetAnswers {
        WidgetAnswers(
            toolCallId: toolCallId,
            title: title?.isEmpty == false ? title : nil,
            questions: questions.map { question -> Components.Schemas.AnsweredQuestion in
                let picked = answers[question.id]
                return Components.Schemas.AnsweredQuestion(
                    id: question.id,
                    prompt: question.prompt,
                    answered: picked != nil,
                    selected: question.options.filter { picked?.contains($0.id) == true }.map { Components.Schemas.QuestionOption(id: $0.id, label: $0.label) }
                )
            }
        )
    }
}

/// How the answers of questions widgets reach the model, as the chat
/// service decides: the next message the user sends carries each widget
/// whose answers changed since a message last carried them.
enum QuestionAnswering {
    /// A widget's answers with changes applied: a question takes the options
    /// picked, or is left unanswered.
    static func applying(_ changes: AnswerChanges, to answers: QuestionAnswers) -> QuestionAnswers {
        var applied = answers
        for (questionId, change) in changes {
            applied[questionId] = change.value
        }
        return applied
    }

    /// The answers the messages last sent of each widget, by widget call.
    static func sentAnswers(in messages: [HarnessMessage]) -> [String: QuestionAnswers] {
        var sent: [String: QuestionAnswers] = [:]
        for message in messages {
            for widget in message.answers ?? [] {
                var picked: QuestionAnswers = [:]
                for question in widget.questions where question.answered {
                    picked[question.id] = question.selected.map(\.id)
                }
                sent[widget.toolCallId] = picked
            }
        }
        return sent
    }

    /// Whether a widget's answers differ from those a message last sent of
    /// it, which then reach the model with the next message. No message
    /// having sent them is as if every question was left unanswered.
    static func isUnsent(_ toolCallId: String, answers: QuestionAnswers, in messages: [HarnessMessage]) -> Bool {
        differ(answers, from: sentAnswers(in: messages)[toolCallId] ?? [:])
    }

    /// The answers the next message sends: those of each questions widget of
    /// the messages' replies, with the changes not saved yet, that differ
    /// from those a message last sent of it.
    static func unsent(in messages: [HarnessMessage], changes: [String: AnswerChanges]) -> [WidgetAnswers] {
        let sent = sentAnswers(in: messages)
        var unsent: [WidgetAnswers] = []
        for message in messages where message.role.value1 == .assistant {
            for block in message.timeline ?? [] where block._type.value1 == .toolCall && block.name == QuestionSet.widgetName {
                guard let questions = QuestionSet(arguments: block.arguments ?? "") else { continue }
                let toolCallId = block.toolCallId ?? block.id
                let answers = applying(changes[toolCallId] ?? [:], to: block.answers?.additionalProperties ?? [:])
                if differ(answers, from: sent[toolCallId] ?? [:]) {
                    unsent.append(questions.sent(toolCallId: toolCallId, answers: answers))
                }
            }
        }
        return unsent
    }

    /// Answers differ when a question is answered in one and not the other,
    /// or is answered with other options, in whatever order.
    private static func differ(_ answers: QuestionAnswers, from sent: QuestionAnswers) -> Bool {
        answers.mapValues { Set($0) } != sent.mapValues { Set($0) }
    }
}
