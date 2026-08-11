//
//  ArtifactPreviewWidget.swift
//  TinfoilChat
//
//  iOS rendering of the webapp's `render_artifact_preview` widget. The
//  webapp version slides a full preview pane over the chat; the iOS
//  version surfaces a tappable summary card that opens a sheet with the
//  artifact contents (URL via in-app browser, HTML/markdown via plain
//  text view).

import OpenAI
import SwiftUI

struct ArtifactPreviewWidget: GenUIWidget {
    enum SourceKind: String, Decodable { case url, html, markdown }

    struct Source: Decodable {
        let type: SourceKind
        let url: String?
        let html: String?
        let markdown: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case url
            case html
            case markdown
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(SourceKind.self, forKey: .type)
            switch type {
            case .url:
                url = try container.decode(String.self, forKey: .url)
                html = nil
                markdown = nil
            case .html:
                url = nil
                html = try container.decode(String.self, forKey: .html)
                markdown = nil
            case .markdown:
                url = nil
                html = nil
                markdown = try container.decode(String.self, forKey: .markdown)
            }
        }
    }

    struct Args: Decodable {
        let title: String?
        let description: String?
        let source: Source
        let footer: String?
    }

    let name = "render_artifact_preview"
    let description = "Display a visual artifact in a side panel: a hosted URL, a self-contained HTML snippet, or Markdown. Use for content worth inspecting at full size — interactive demos, long-form documents, or rich HTML mockups. For SVG illustrations and Mermaid diagrams, emit a fenced `svg` or `mermaid` code block in the regular assistant message instead. The chat shows a compact summary card; clicking it opens the full artifact in the right sidebar."
    let promptHint = "large artifacts opened in a side panel; arguments use source with type url, html, or markdown and the matching url, html, or markdown payload field"

    var schema: JSONSchema {
        let urlSource = GenUISchema.object(
            properties: [
                "type": GenUISchema.string(enumValues: ["url"]),
                "url": GenUISchema.string(description: "Absolute URL for the hosted artifact"),
            ],
            required: ["type", "url"]
        )
        let htmlSource = GenUISchema.object(
            properties: [
                "type": GenUISchema.string(enumValues: ["html"]),
                "html": GenUISchema.string(description: "Complete self-contained HTML artifact"),
            ],
            required: ["type", "html"]
        )
        let markdownSource = GenUISchema.object(
            properties: [
                "type": GenUISchema.string(enumValues: ["markdown"]),
                "markdown": GenUISchema.string(description: "Complete Markdown artifact"),
            ],
            required: ["type", "markdown"]
        )
        return GenUISchema.object(
            properties: [
                "title": GenUISchema.string(),
                "description": GenUISchema.string(),
                "source": JSONSchema(fields: [
                    .oneOf([urlSource, htmlSource, markdownSource]),
                    .description("Complete artifact payload. Choose one source type and include its matching payload field."),
                ]),
                "footer": GenUISchema.string(),
            ],
            required: ["source"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(ArtifactPreviewView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct ArtifactPreviewView: View {
    let args: ArtifactPreviewWidget.Args
    let isDarkMode: Bool

    @State private var showSheet: Bool = false

    private var sourceLabel: String {
        switch args.source.type {
        case .url: return "Hosted preview"
        case .html: return "HTML artifact"
        case .markdown: return "Markdown artifact"
        }
    }

    var body: some View {
        Button(action: openArtifact) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(args.title ?? sourceLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .lineLimit(1)
                    Text(args.description ?? sourceLabel)
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
            .genUICard(isDarkMode: isDarkMode, padding: 14)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(args.title ?? sourceLabel)
        .accessibilityHint("Opens preview")
        .sheet(isPresented: $showSheet) {
            ArtifactDetailSheet(args: args, isDarkMode: isDarkMode)
        }
    }

    private func openArtifact() {
        if args.source.type == .url, let url = args.source.url {
            GenUIURLOpener.open(url)
        } else {
            showSheet = true
        }
    }
}

private struct ArtifactDetailSheet: View {
    let args: ArtifactPreviewWidget.Args
    let isDarkMode: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let description = args.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    }
                    Divider()
                    contentBody
                    if let footer = args.footer, !footer.isEmpty {
                        Divider()
                        Text(footer)
                            .font(.caption)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    }
                }
                .padding()
            }
            .navigationTitle(args.title ?? "Artifact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch args.source.type {
        case .markdown:
            if let markdown = args.source.markdown {
                if let attributed = try? AttributedString(markdown: markdown) {
                    Text(attributed)
                        .font(.body)
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                } else {
                    Text(markdown)
                        .font(.body)
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                }
            }
        case .html:
            if let html = args.source.html {
                Text(html)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .url:
            if let url = args.source.url {
                Button(action: { GenUIURLOpener.open(url) }) {
                    Text(url)
                        .font(.subheadline)
                        .underline()
                        .foregroundColor(GenUIStyle.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
