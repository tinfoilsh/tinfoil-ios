//
//  QuoteWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct QuoteWidget: GenUIWidget {
    struct Args: Decodable {
        let text: String
        let author: String?
        let role: String?
        let source: String?
        let sourceUrl: String?
        let publishedAt: String?
    }

    let name = "render_quote"
    let description = "Display a pull-quote with optional attribution. Use when surfacing a direct quote, testimonial, or notable statement."
    let promptHint = "a pull-quote with attribution"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "text": GenUISchema.string(description: "The quoted text"),
                "author": GenUISchema.string(),
                "role": GenUISchema.string(description: "The author's role or title"),
                "source": GenUISchema.string(),
                "sourceUrl": GenUISchema.string(),
                "publishedAt": GenUISchema.string(),
            ],
            required: ["text"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(QuoteView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct QuoteView: View {
    let args: QuoteWidget.Args
    let isDarkMode: Bool

    private var hasAttribution: Bool {
        [args.author, args.role, args.source, args.publishedAt]
            .compactMap { $0 }
            .contains { !$0.isEmpty }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(GenUIStyle.borderColor(isDarkMode))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 8) {
                Text("\u{201C}\(args.text)\u{201D}")
                    .font(.body.italic())
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .fixedSize(horizontal: false, vertical: true)

                if hasAttribution {
                    attributionLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var attributionLine: some View {
        let parts: [(text: String, isAuthor: Bool, link: String?)] = {
            var result: [(String, Bool, String?)] = []
            if let author = args.author, !author.isEmpty {
                result.append((author, true, nil))
            }
            if let role = args.role, !role.isEmpty {
                result.append((role, false, nil))
            }
            if let source = args.source, !source.isEmpty {
                result.append((source, false, args.sourceUrl))
            }
            if let publishedAt = args.publishedAt, !publishedAt.isEmpty {
                result.append((publishedAt, false, nil))
            }
            return result
        }()

        HStack(spacing: 6) {
            Text("\u{2014}")
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("\u{00B7}")
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                if let link = part.link {
                    Button(action: { GenUIURLOpener.open(link) }) {
                        HStack(spacing: 2) {
                            Text(part.text).underline()
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                } else {
                    Text(part.text)
                        .foregroundColor(part.isAuthor
                                         ? GenUIStyle.primaryText(isDarkMode)
                                         : GenUIStyle.mutedText(isDarkMode))
                }
            }
        }
        .font(.footnote)
    }
}
