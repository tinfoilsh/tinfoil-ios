//
//  SourceCardsWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct SourceCardsWidget: GenUIWidget {
    struct Source: Decodable {
        let title: String
        let url: String
        let snippet: String?
        let publishedAt: String?
        let author: String?
        let image: String?
    }

    struct Args: Decodable {
        let sources: [Source]
        let title: String?
    }

    let name = "render_source_cards"
    let description = "Display multiple source references as a grid of cards. Use when presenting research citations, search results, or reference reading lists."
    let promptHint = "a grid of reference source cards"

    var schema: JSONSchema {
        let source = GenUISchema.object(
            properties: [
                "title": GenUISchema.string(),
                "url": GenUISchema.string(),
                "snippet": GenUISchema.string(),
                "publishedAt": GenUISchema.string(),
                "author": GenUISchema.string(),
                "image": GenUISchema.string(),
            ],
            required: ["title", "url"]
        )
        return GenUISchema.object(
            properties: [
                "sources": GenUISchema.array(
                    items: source,
                    description: "Reference sources to surface as a grid of cards",
                    minItems: 1
                ),
                "title": GenUISchema.string(),
            ],
            required: ["sources"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(SourceCardsView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct SourceCardsView: View {
    let args: SourceCardsWidget.Args
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = args.title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }
            VStack(spacing: 8) {
                ForEach(Array(args.sources.enumerated()), id: \.offset) { _, source in
                    SourceCardRow(source: source, isDarkMode: isDarkMode)
                }
            }
        }
    }
}

private struct SourceCardRow: View {
    let source: SourceCardsWidget.Source
    let isDarkMode: Bool

    private var domain: String {
        guard let url = URL(string: source.url), let host = url.host else { return source.url }
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    var body: some View {
        Button(action: { GenUIURLOpener.open(source.url) }) {
            HStack(alignment: .top, spacing: 10) {
                if let image = source.image, !image.isEmpty {
                    GenUIRemoteImage(url: image, isDarkMode: isDarkMode)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    FaviconView(url: source.url, isDarkMode: isDarkMode)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(domain)
                            .font(.caption)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                            .lineLimit(1)
                    }
                    Text(source.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if let snippet = source.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    if source.publishedAt != nil || source.author != nil {
                        HStack(spacing: 6) {
                            if let author = source.author, !author.isEmpty {
                                Text(author)
                            }
                            if source.author != nil && source.publishedAt != nil {
                                Text("\u{00B7}")
                            }
                            if let publishedAt = source.publishedAt, !publishedAt.isEmpty {
                                Text(publishedAt)
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .genUICard(isDarkMode: isDarkMode, padding: 10)
        }
        .buttonStyle(.plain)
    }
}
