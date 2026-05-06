//
//  LinkPreviewWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

private let linkPreviewImageSize: CGFloat = 112
private let linkPreviewCornerRadius: CGFloat = 12
private let linkPreviewCardPadding: CGFloat = 12
private let linkPreviewFaviconSize: CGFloat = 16

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

    @State private var metadata: LinkMetadata?

    private var domain: String {
        guard let url = URL(string: args.url), let host = url.host else { return args.url }
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    private var displayTitle: String {
        if let title = metadata?.title, !title.isEmpty { return title }
        return args.title
    }

    private var displaySiteName: String {
        if let siteName = metadata?.siteName, !siteName.isEmpty { return siteName }
        return domain
    }

    var body: some View {
        Button(action: { GenUIURLOpener.open(args.url) }) {
            HStack(alignment: .top, spacing: 0) {
                if let image = metadata?.image, !image.isEmpty {
                    GenUIRemoteImage(url: image, isDarkMode: isDarkMode, contentMode: .fill)
                        .frame(width: linkPreviewImageSize, height: linkPreviewImageSize)
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        FaviconView(url: args.url, isDarkMode: isDarkMode)
                            .frame(width: linkPreviewFaviconSize, height: linkPreviewFaviconSize)
                        Text(displaySiteName)
                            .font(.caption)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                            .lineLimit(1)
                    }
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if let description = metadata?.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
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
                .padding(linkPreviewCardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GenUIStyle.cardBackground(isDarkMode))
            .clipShape(RoundedRectangle(cornerRadius: linkPreviewCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: linkPreviewCornerRadius)
                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .task(id: args.url) {
            await MainActor.run { metadata = nil }
            do {
                let result = try await LinkMetadataService.shared.metadata(for: args.url)
                await MainActor.run { metadata = result }
            } catch {
                // Keep model-provided title; render the leaner card.
            }
        }
    }
}
