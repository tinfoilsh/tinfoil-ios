//
//  RecipeCardWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

private let recipeScaleOptions: [Double] = [1, 2, 3]
private let defaultRecipeScale: Double = 1
private let recipeAccent = Color.orange
private let scaledRecipeQuantityColor = recipeAccent
private let fractionMatchTolerance = 0.02
private let quantityPattern = #"\d+\s+\d+/\d+|\d+/\d+|\d+[⅛¼⅓⅜½⅝⅔¾⅞]|\d*\.?\d+|[⅛¼⅓⅜½⅝⅔¾⅞]"#

private let unicodeFractions: [String: Double] = [
    "⅛": 1.0 / 8.0,
    "¼": 1.0 / 4.0,
    "⅓": 1.0 / 3.0,
    "⅜": 3.0 / 8.0,
    "½": 1.0 / 2.0,
    "⅝": 5.0 / 8.0,
    "⅔": 2.0 / 3.0,
    "¾": 3.0 / 4.0,
    "⅞": 7.0 / 8.0,
]

private let fractionLabels: [(value: Double, label: String)] = [
    (1.0 / 8.0, "⅛"),
    (1.0 / 4.0, "¼"),
    (1.0 / 3.0, "⅓"),
    (3.0 / 8.0, "⅜"),
    (1.0 / 2.0, "½"),
    (5.0 / 8.0, "⅝"),
    (2.0 / 3.0, "⅔"),
    (3.0 / 4.0, "¾"),
    (7.0 / 8.0, "⅞"),
]

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
        let sourceUrl: String?
        let source: String?
    }

    let name = "render_recipe_card"
    let description = "Display a cookable recipe card with ingredients and step-by-step instructions. Use when presenting a recipe, cooking procedure, or multi-step preparation with ingredients."
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
    @State private var recipeScale: Double = defaultRecipeScale

    private var difficultyText: String? {
        guard let value = args.difficulty, !value.isEmpty else { return nil }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    private var cuisineText: String? {
        guard let cuisine = args.cuisine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cuisine.isEmpty else { return nil }
        return cuisine
    }

    private var hasSource: Bool {
        if let source = args.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            return true
        }
        if let sourceUrl = args.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceUrl.isEmpty {
            return true
        }
        return false
    }

    private struct MetaItem: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let value: String
        let scaled: Bool
    }

    private var metaItems: [MetaItem] {
        var items: [MetaItem] = []
        if let prep = args.prepTime, !prep.isEmpty {
            items.append(.init(icon: "clock", label: "PREP", value: prep, scaled: false))
        }
        if let cook = args.cookTime, !cook.isEmpty {
            items.append(.init(icon: "flame", label: "COOK", value: cook, scaled: false))
        }
        if items.isEmpty, let total = args.totalTime, !total.isEmpty {
            items.append(.init(icon: "clock", label: "TOTAL", value: total, scaled: false))
        }
        if let servings = args.servings?.stringValue, !servings.isEmpty {
            let scaledServings = scaleQuantityText(servings, scale: recipeScale)
            items.append(.init(
                icon: "person.2",
                label: "SERVES",
                value: scaledServings,
                scaled: recipeScale != defaultRecipeScale && scaledServings != servings
            ))
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
                if cuisineText != nil || difficultyText != nil {
                    HStack(spacing: 4) {
                        if let cuisine = cuisineText {
                            Text(cuisine.uppercased()).tracking(1.5)
                        }
                        if cuisineText != nil && difficultyText != nil {
                            Text("\u{00B7}")
                        }
                        if let diff = difficultyText {
                            Text(diff)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(recipeAccent)
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
                scaleControl
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

            if hasSource {
                sourceRow
            }
        }
        .genUICard(isDarkMode: isDarkMode, padding: 16)
    }

    @ViewBuilder
    private var metaRow: some View {
        RecipeTagFlowLayout(spacing: 8) {
            ForEach(metaItems) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.caption.weight(.medium))
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                        Text(item.value)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundColor(item.scaled ? scaledRecipeQuantityColor : GenUIStyle.primaryText(isDarkMode))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(GenUIStyle.subtleBackground(isDarkMode))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var scaleControl: some View {
        HStack(spacing: 10) {
            Text("SCALE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                .padding(.leading, 10)
                .padding(.trailing, 2)
            ForEach(recipeScaleOptions, id: \.self) { scale in
                Button(action: { recipeScale = scale }) {
                    Text(scaleLabel(scale))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundColor(scaleButtonForeground(scale))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(scaleButtonBackground(scale))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(GenUIStyle.subtleBackground(isDarkMode))
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(1.4)
            .foregroundColor(recipeAccent)
    }

    @ViewBuilder
    private func ingredientRow(index: Int, ingredient: RecipeCardWidget.Ingredient) -> some View {
        let checked = checkedIngredients.contains(index)
        Button(action: {
            if checked { checkedIngredients.remove(index) } else { checkedIngredients.insert(index) }
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundColor(checked ? recipeAccent : GenUIStyle.mutedText(isDarkMode))
                    .font(.subheadline)
                ingredientText(ingredient, checked: checked)
                .font(.subheadline)
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
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityHint(checked ? "Mark as not done" : "Mark as done")
    }

    private func ingredientText(_ ingredient: RecipeCardWidget.Ingredient, checked: Bool) -> Text {
        let primaryColor = checked ? GenUIStyle.mutedText(isDarkMode) : GenUIStyle.primaryText(isDarkMode)
        guard let quantity = ingredient.quantity, !quantity.isEmpty else {
            return Text(ingredient.item).foregroundColor(primaryColor)
        }

        let quantityColor = checked || recipeScale == defaultRecipeScale ? primaryColor : scaledRecipeQuantityColor
        return Text(scaleQuantityText(quantity, scale: recipeScale) + " ")
            .bold()
            .foregroundColor(quantityColor) +
            Text(ingredient.item)
            .foregroundColor(primaryColor)
    }

    private func scaleLabel(_ scale: Double) -> String {
        "\(Int(scale))x"
    }

    private func scaleButtonForeground(_ scale: Double) -> Color {
        if scale == recipeScale {
            return .white
        }
        return GenUIStyle.mutedText(isDarkMode)
    }

    private func scaleButtonBackground(_ scale: Double) -> Color {
        guard scale == recipeScale else { return Color.clear }
        return recipeAccent
    }

    @ViewBuilder
    private func stepRow(index: Int, step: RecipeCardWidget.Step) -> some View {
        let done = completedSteps.contains(index)
        Button(action: {
            if done { completedSteps.remove(index) } else { completedSteps.insert(index) }
        }) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    if done {
                        Circle().fill(recipeAccent)
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                    } else {
                        Circle().fill(recipeAccent.opacity(0.14))
                            .frame(width: 24, height: 24)
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(recipeAccent)
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
        .accessibilityAddTraits(done ? .isSelected : [])
        .accessibilityHint(done ? "Mark step as not done" : "Mark step as done")
    }

    @ViewBuilder
    private var sourceRow: some View {
        HStack {
            Text("Source: ")
                .font(.caption)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            if let url = args.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                Button(action: { GenUIURLOpener.open(url) }) {
                    Text(sourceLabel(fallback: url))
                        .underline()
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                .buttonStyle(.plain)
            } else if let source = args.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
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

    private func sourceLabel(fallback: String) -> String {
        guard let source = args.source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return fallback }
        return source
    }
}

private func scaleQuantityText(_ value: String, scale: Double) -> String {
    guard scale != defaultRecipeScale,
          let regex = try? NSRegularExpression(pattern: quantityPattern) else {
        return value
    }

    var result = value
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = regex.matches(in: value, range: range).reversed()
    for match in matches {
        guard let tokenRange = Range(match.range, in: result) else { continue }
        let token = String(result[tokenRange])
        guard let amount = parseQuantityToken(token) else { continue }
        result.replaceSubrange(tokenRange, with: formatScaledQuantity(amount * scale))
    }
    return result
}

private func parseQuantityToken(_ token: String) -> Double? {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if let fraction = unicodeFractions[trimmed] {
        return fraction
    }

    // Compact mixed unicode fractions like `1½` or `2¾`: a run of digits
    // followed by a single unicode fraction character with no separator.
    if let lastScalar = trimmed.unicodeScalars.last,
       let fraction = unicodeFractions[String(lastScalar)],
       trimmed.unicodeScalars.count > 1 {
        let wholePart = String(trimmed.unicodeScalars.dropLast())
        if let whole = Double(wholePart) {
            return whole + fraction
        }
    }

    let parts = trimmed.split(separator: " ")
    if parts.count == 2,
       let whole = Double(parts[0]),
       let fraction = parseSlashFraction(String(parts[1])) {
        return whole + fraction
    }

    if let fraction = parseSlashFraction(trimmed) {
        return fraction
    }

    return Double(trimmed)
}

private func parseSlashFraction(_ value: String) -> Double? {
    let parts = value.split(separator: "/")
    guard parts.count == 2,
          let numerator = Double(parts[0]),
          let denominator = Double(parts[1]),
          denominator != 0 else {
        return nil
    }
    return numerator / denominator
}

private func formatScaledQuantity(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }

    let whole = floor(value)
    let fraction = value - whole
    if let match = fractionLabels.first(where: { abs($0.value - fraction) < fractionMatchTolerance }) {
        return whole > 0 ? "\(Int(whole)) \(match.label)" : match.label
    }

    let formatted = String(format: "%.2f", value)
    return formatted
        .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
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
            // Only wrap when the row already has content; an item wider
            // than the container still goes on the current row (and gets
            // clipped) instead of forcing an empty leading row.
            if x > 0, x + size.width > maxWidth {
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
            if x > bounds.minX, x + size.width > bounds.maxX {
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
