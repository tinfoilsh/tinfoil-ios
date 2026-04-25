//
//  RecipeCardWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct RecipeCardWidget: GenUIWidget {
    struct Ingredient: Decodable {
        let quantity: String?
        let item: String
        let note: String?
    }

    struct Step: Decodable {
        let title: String?
        let content: String
    }

    struct Args: Decodable {
        let title: String
        let description: String?
        let image: String?
        let cuisine: String?
        let difficulty: String?
        let servings: StringOrNumber?
        let prepTime: String?
        let cookTime: String?
        let totalTime: String?
        let ingredients: [Ingredient]?
        let steps: [Step]?
        let tags: [String]?
        let sourceUrl: String?
        let source: String?
    }

    let name = "render_recipe_card"
    let description = "Display a cookable recipe card with ingredients and step-by-step instructions."
    let promptHint = "a cookable recipe card with ingredients and steps"

    var schema: JSONSchema {
        let ingredient = GenUISchema.object(
            properties: [
                "quantity": GenUISchema.string(),
                "item": GenUISchema.string(),
                "note": GenUISchema.string(),
            ],
            required: ["item"]
        )
        let step = GenUISchema.object(
            properties: [
                "title": GenUISchema.string(),
                "content": GenUISchema.string(),
            ],
            required: ["content"]
        )
        return GenUISchema.object(
            properties: [
                "title": GenUISchema.string(),
                "description": GenUISchema.string(),
                "image": GenUISchema.string(),
                "cuisine": GenUISchema.string(),
                "difficulty": GenUISchema.string(enumValues: ["easy", "medium", "hard"]),
                "servings": GenUISchema.stringOrNumber(),
                "prepTime": GenUISchema.string(),
                "cookTime": GenUISchema.string(),
                "totalTime": GenUISchema.string(),
                "ingredients": GenUISchema.array(items: ingredient),
                "steps": GenUISchema.array(items: step),
                "tags": GenUISchema.array(items: GenUISchema.string()),
                "sourceUrl": GenUISchema.string(),
                "source": GenUISchema.string(),
            ],
            required: ["title"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(RecipeCardView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct RecipeCardView: View {
    let args: RecipeCardWidget.Args
    let isDarkMode: Bool

    @State private var checkedIngredients: Set<Int> = []
    @State private var completedSteps: Set<Int> = []

    private var difficultyText: String? {
        guard let value = args.difficulty, !value.isEmpty else { return nil }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    private struct MetaItem: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let value: String
    }

    private var metaItems: [MetaItem] {
        var items: [MetaItem] = []
        if let prep = args.prepTime, !prep.isEmpty {
            items.append(.init(icon: "clock", label: "PREP", value: prep))
        }
        if let cook = args.cookTime, !cook.isEmpty {
            items.append(.init(icon: "flame", label: "COOK", value: cook))
        }
        if items.isEmpty, let total = args.totalTime, !total.isEmpty {
            items.append(.init(icon: "clock", label: "TOTAL", value: total))
        }
        if let servings = args.servings?.stringValue, !servings.isEmpty {
            items.append(.init(icon: "person.2", label: "SERVES", value: servings))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let image = args.image, !image.isEmpty {
                GenUIRemoteImage(url: image, isDarkMode: isDarkMode, contentMode: .fill)
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius))
            }

            VStack(alignment: .center, spacing: 6) {
                if args.cuisine != nil || difficultyText != nil {
                    HStack(spacing: 4) {
                        if let cuisine = args.cuisine, !cuisine.isEmpty {
                            Text(cuisine.uppercased()).tracking(1.5)
                        }
                        if args.cuisine != nil && difficultyText != nil {
                            Text("\u{00B7}")
                        }
                        if let diff = difficultyText {
                            Text(diff)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                Text(args.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                if let description = args.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
            }
            .frame(maxWidth: .infinity)

            if !metaItems.isEmpty {
                metaRow
            }

            if let ingredients = args.ingredients, !ingredients.isEmpty {
                sectionHeader("INGREDIENTS")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(ingredients.enumerated()), id: \.offset) { index, ingredient in
                        ingredientRow(index: index, ingredient: ingredient)
                    }
                }
            }

            if let steps = args.steps, !steps.isEmpty {
                sectionHeader("STEPS")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        stepRow(index: index, step: step)
                    }
                }
            }

            if let tags = args.tags, !tags.isEmpty {
                tagRow(tags: tags)
            }

            if args.source != nil || args.sourceUrl != nil {
                sourceRow
            }
        }
        .genUICard(isDarkMode: isDarkMode, padding: 16)
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 6) {
            ForEach(metaItems) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.icon)
                        .font(.caption2)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    Text(item.label)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    Text(item.value)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(1.0)
            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
    }

    @ViewBuilder
    private func ingredientRow(index: Int, ingredient: RecipeCardWidget.Ingredient) -> some View {
        let checked = checkedIngredients.contains(index)
        Button(action: {
            if checked { checkedIngredients.remove(index) } else { checkedIngredients.insert(index) }
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundColor(checked ? GenUIStyle.primaryText(isDarkMode) : GenUIStyle.mutedText(isDarkMode))
                    .font(.subheadline)
                Group {
                    if let qty = ingredient.quantity, !qty.isEmpty {
                        Text(qty + " ").bold() + Text(ingredient.item)
                    } else {
                        Text(ingredient.item)
                    }
                }
                .font(.subheadline)
                .foregroundColor(checked ? GenUIStyle.mutedText(isDarkMode) : GenUIStyle.primaryText(isDarkMode))
                .strikethrough(checked)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let note = ingredient.note, !note.isEmpty {
                    Text("(\(note))")
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func stepRow(index: Int, step: RecipeCardWidget.Step) -> some View {
        let done = completedSteps.contains(index)
        Button(action: {
            if done { completedSteps.remove(index) } else { completedSteps.insert(index) }
        }) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                        .frame(width: 24, height: 24)
                    if done {
                        Circle().fill(GenUIStyle.primaryText(isDarkMode))
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundColor(isDarkMode ? .black : .white)
                    } else {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = step.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(done ? GenUIStyle.mutedText(isDarkMode) : GenUIStyle.primaryText(isDarkMode))
                            .strikethrough(done)
                    }
                    Text(step.content)
                        .font(.subheadline)
                        .foregroundColor(done ? GenUIStyle.mutedText(isDarkMode) : GenUIStyle.primaryText(isDarkMode))
                        .strikethrough(done)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius)
                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tagRow(tags: [String]) -> some View {
        RecipeTagFlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(.caption2)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private var sourceRow: some View {
        HStack {
            Text("Source: ")
                .font(.caption)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            if let url = args.sourceUrl, !url.isEmpty {
                Button(action: { GenUIURLOpener.open(url) }) {
                    Text(args.source ?? url)
                        .underline()
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                .buttonStyle(.plain)
            } else if let source = args.source, !source.isEmpty {
                Text(source)
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
            Spacer()
        }
        .padding(.top, 6)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(GenUIStyle.borderColor(isDarkMode))
                .padding(.top, 0),
            alignment: .top
        )
    }
}

/// Minimal flow layout for tag rows (works on iOS 16+).
private struct RecipeTagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
