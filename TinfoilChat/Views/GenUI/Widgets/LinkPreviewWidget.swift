//
//  LinkPreviewWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct LinkPreviewWidget: GenUIWidget {
    struct Args: Decodable {
        let url: String
        let title: String
    }

    let name = "render_link_preview"
    let description = "Display a rich preview card for a single web link. Use when linking to an article, page, or resource and you want to surface title and favicon."
    let promptHint = "rich preview card for a single web link"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "url": GenUISchema.string(description: "Full URL of the resource"),
                "title": GenUISchema.string(description: "Best guess at the page title"),
            ],
            required: ["url", "title"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(LinkPreviewView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct LinkPreviewView: View {
    let args: LinkPreviewWidget.Args
    let isDarkMode: Bool

    private var domain: String {
        guard let url = URL(string: args.url), let host = url.host else { return args.url }
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    var body: some View {
        Button(action: { GenUIURLOpener.open(args.url) }) {
            HStack(alignment: .center, spacing: 12) {
                FaviconView(url: args.url, isDarkMode: isDarkMode)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(args.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text(domain)
                            .font(.caption)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .genUICard(isDarkMode: isDarkMode, padding: 12)
        }
        .buttonStyle(.plain)
    }
}
