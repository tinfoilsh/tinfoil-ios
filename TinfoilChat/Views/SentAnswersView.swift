//
//  SentAnswersView.swift
//  TinfoilChat
//

import SwiftUI

private enum SentAnswersLayout {
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 10
    static let headerSpacing: CGFloat = 8
    static let questionSpacing: CGFloat = 2
    static let mutedOpacity = 0.65
    static let chevronExpandedRotation = 180.0
    static let animationDuration = 0.2
}

private enum SentAnswersSymbol {
    static let answers = "checklist"
    static let chevron = "chevron.down"
}

/// The answers a message sent to questions widgets: a card that counts the
/// questions answered, and lists each with the options picked once opened.
struct SentAnswersView: View {
    let answers: [WidgetAnswers]
    let isDarkMode: Bool

    @State private var isExpanded = false

    private var answeredCount: Int {
        answers.reduce(0) { count, widget in count + widget.questions.filter(\.answered).count }
    }

    private var summary: String {
        switch answeredCount {
        case 0: return "No questions answered"
        case 1: return "Answered 1 question"
        default: return "Answered \(answeredCount) questions"
        }
    }

    private var foreground: Color {
        Color.userMessageForeground(isDarkMode: isDarkMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SentAnswersLayout.spacing) {
            Button {
                withAnimation(.easeInOut(duration: SentAnswersLayout.animationDuration)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: SentAnswersLayout.headerSpacing) {
                    Image(systemName: SentAnswersSymbol.answers)
                        .accessibilityHidden(true)
                    Text(summary)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: SentAnswersSymbol.chevron)
                        .font(.caption)
                        .rotationEffect(.degrees(isExpanded ? SentAnswersLayout.chevronExpandedRotation : 0))
                        .accessibilityHidden(true)
                }
                .foregroundColor(foreground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the answers" : "Shows the answers")

            if isExpanded {
                ForEach(Array(answers.enumerated()), id: \.offset) { _, widget in
                    VStack(alignment: .leading, spacing: SentAnswersLayout.spacing) {
                        if let title = widget.title, !title.isEmpty {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(foreground.opacity(SentAnswersLayout.mutedOpacity))
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(widget.questions.enumerated()), id: \.offset) { _, question in
                            VStack(alignment: .leading, spacing: SentAnswersLayout.questionSpacing) {
                                Text(question.prompt)
                                    .foregroundColor(foreground)
                                Text(Self.answer(question))
                                    .foregroundColor(foreground.opacity(SentAnswersLayout.mutedOpacity))
                            }
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .padding(SentAnswersLayout.padding)
        .background {
            if #available(iOS 26, *) {
                RoundedRectangle(cornerRadius: SentAnswersLayout.cornerRadius)
                    .fill(.thickMaterial)
            } else {
                RoundedRectangle(cornerRadius: SentAnswersLayout.cornerRadius)
                    .fill(Color.userMessageBackground(isDarkMode: isDarkMode))
            }
        }
    }

    /// What a question was answered with, as the model read it.
    private static func answer(_ question: Components.Schemas.AnsweredQuestion) -> String {
        guard question.answered else { return "Not answered" }
        guard !question.selected.isEmpty else { return "None selected" }
        return question.selected.map(\.label).joined(separator: ", ")
    }
}
