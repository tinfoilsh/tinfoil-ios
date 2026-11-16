//
//  QuestionsWidget.swift
//  TinfoilChat
//

import SwiftUI
import TinfoilIcons

private enum QuestionsLayout {
    static let sectionSpacing: CGFloat = 16
    static let headerSpacing: CGFloat = 4
    static let promptSpacing: CGFloat = 8
    static let optionSpacing: CGFloat = 6
    static let indicatorSpacing: CGFloat = 10
    static let optionHorizontalPadding: CGFloat = 12
    static let optionVerticalPadding: CGFloat = 10
    static let optionBorderWidth: CGFloat = 1
    static let selectedFillOpacity = 0.12
    static let selectedBorderOpacity = 0.6
    static let footerSpacing: CGFloat = 10
    static let statusSpacing: CGFloat = 6
    static let submitHorizontalPadding: CGFloat = 14
    static let submitVerticalPadding: CGFloat = 8
    static let disabledSubmitOpacity = 0.4
}

private enum QuestionsSymbol {
    static let singleSelected: TinfoilIcon = .circleDot
    static let single: TinfoilIcon = .circle
    static let multipleSelected: TinfoilIcon = .boxCheck
    static let multiple: TinfoilIcon = .square
    static let saveFailed: TinfoilIcon = .exclamationCircle
}

struct QuestionsWidget: GenUIWidget {
    typealias Args = QuestionSet

    let name = QuestionSet.widgetName

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(QuestionsView(args: args, isDarkMode: context.isDarkMode, answering: context.answering))
    }
}

/// The questions and their options, picked in place. What is picked, and
/// whether it can change, come from the chat, so they outlast the view.
private struct QuestionsView: View {
    let args: QuestionSet
    let isDarkMode: Bool
    let answering: GenUIAnswering?

    private var state: GenUIAnswersState {
        answering?.state ?? GenUIAnswersState()
    }

    private var answeredCount: Int {
        args.questions.filter { state.answers[$0.id] != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: QuestionsLayout.sectionSpacing) {
            VStack(alignment: .leading, spacing: QuestionsLayout.headerSpacing) {
                if let title = args.title, !title.isEmpty {
                    GenUITitle(text: title, isDarkMode: isDarkMode)
                        .accessibilityAddTraits(.isHeader)
                }
                Text("\(answeredCount) of \(args.questions.count) answered")
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }

            ForEach(args.questions, id: \.id) { question in
                questionView(question)
            }

            if let answering {
                footer(answering)
            }
        }
        .genUICard(isDarkMode: isDarkMode)
        .accessibilityElement(children: .contain)
    }

    private func questionView(_ question: QuestionSet.Question) -> some View {
        VStack(alignment: .leading, spacing: QuestionsLayout.promptSpacing) {
            VStack(alignment: .leading, spacing: QuestionsLayout.headerSpacing) {
                Text(question.prompt)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(question.selection == .single ? "Choose one" : "Choose any that apply")
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
            VStack(spacing: QuestionsLayout.optionSpacing) {
                ForEach(question.options, id: \.id) { option in
                    optionRow(option, of: question)
                }
            }
        }
    }

    private func optionRow(_ option: QuestionSet.Option, of question: QuestionSet.Question) -> some View {
        let selected = state.answers[question.id]?.contains(option.id) == true
        let shape = RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius)
        return Button {
            pick(option, of: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: QuestionsLayout.indicatorSpacing) {
                Image(tinfoil: indicator(for: question.selection, selected: selected))
                    .font(.body)
                    .foregroundColor(selected ? GenUIStyle.accent : GenUIStyle.mutedText(isDarkMode))
                    .accessibilityHidden(true)
                Text(option.label)
                    .font(.subheadline)
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, QuestionsLayout.optionHorizontalPadding)
            .padding(.vertical, QuestionsLayout.optionVerticalPadding)
            .background(
                shape.fill(selected ? GenUIStyle.accent.opacity(QuestionsLayout.selectedFillOpacity) : GenUIStyle.subtleBackground(isDarkMode))
            )
            .overlay(
                shape.stroke(
                    selected ? GenUIStyle.accent.opacity(QuestionsLayout.selectedBorderOpacity) : GenUIStyle.borderColor(isDarkMode),
                    lineWidth: QuestionsLayout.optionBorderWidth
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!state.canAnswer)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(hint(for: question.selection, selected: selected))
    }

    /// A single-choice question takes the option tapped, and is left
    /// unanswered when it is tapped again. A checklist ticks or unticks the
    /// option, and is left unanswered once nothing is ticked.
    private func pick(_ option: QuestionSet.Option, of question: QuestionSet.Question) {
        guard let answering, state.canAnswer else { return }
        let picked = state.answers[question.id] ?? []
        switch question.selection {
        case .single:
            answering.answer(question.id, picked.contains(option.id) ? nil : [option.id])
        case .multiple:
            let toggled = picked.contains(option.id) ? picked.filter { $0 != option.id } : picked + [option.id]
            let ordered = question.options.map(\.id).filter { toggled.contains($0) }
            answering.answer(question.id, ordered.isEmpty ? nil : ordered)
        }
    }

    private func indicator(for selection: QuestionSet.Selection, selected: Bool) -> TinfoilIcon {
        switch selection {
        case .single: return selected ? QuestionsSymbol.singleSelected : QuestionsSymbol.single
        case .multiple: return selected ? QuestionsSymbol.multipleSelected : QuestionsSymbol.multiple
        }
    }

    private func hint(for selection: QuestionSet.Selection, selected: Bool) -> String {
        switch selection {
        case .single: return selected ? "Clears this answer" : "Chooses this answer"
        case .multiple: return selected ? "Unticks this option" : "Ticks this option"
        }
    }

    private func footer(_ answering: GenUIAnswering) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: QuestionsLayout.footerSpacing) {
                saveStatus(answering)
                Spacer(minLength: 0)
                submitButton(answering)
            }
            VStack(alignment: .leading, spacing: QuestionsLayout.footerSpacing) {
                saveStatus(answering)
                submitButton(answering)
            }
        }
    }

    @ViewBuilder
    private func saveStatus(_ answering: GenUIAnswering) -> some View {
        switch answering.state.saveStatus {
        case .saving:
            HStack(spacing: QuestionsLayout.statusSpacing) {
                ProgressView()
                    .controlSize(.mini)
                Text("Saving…")
            }
            .font(.caption)
            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            .accessibilityElement(children: .combine)
        case .failed:
            HStack(spacing: QuestionsLayout.statusSpacing) {
                Image(tinfoil: QuestionsSymbol.saveFailed)
                    .foregroundColor(.red)
                    .accessibilityHidden(true)
                Text("Couldn't save")
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                Button("Try again", action: answering.retry)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .buttonStyle(.plain)
                    .disabled(!answering.state.canAnswer)
            }
            .font(.caption)
        case nil:
            EmptyView()
        }
    }

    private func submitButton(_ answering: GenUIAnswering) -> some View {
        Button(action: answering.submit) {
            Text("Submit answers")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(isDarkMode ? .black : .white)
                .padding(.horizontal, QuestionsLayout.submitHorizontalPadding)
                .padding(.vertical, QuestionsLayout.submitVerticalPadding)
                .background(Capsule().fill(GenUIStyle.primaryText(isDarkMode)))
        }
        .buttonStyle(.plain)
        .disabled(!answering.state.canSubmit)
        .opacity(answering.state.canSubmit ? 1 : QuestionsLayout.disabledSubmitOpacity)
    }
}
