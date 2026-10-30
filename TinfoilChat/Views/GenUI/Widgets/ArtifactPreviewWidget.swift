//
//  ArtifactPreviewWidget.swift
//  TinfoilChat
//
//  iOS rendering of the webapp's `render_artifact_preview` widget. The
//  webapp version slides a full preview pane over the chat; the iOS
//  version surfaces a tappable summary card that opens a sheet with the
//  artifact contents (URL in the browser, HTML in a sandboxed web view
//  with its source one tap away, markdown rendered like a chat message).

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
    @State private var showsSource = false
    @State private var isPreviewUnavailable = false

    private var canPreviewHTML: Bool {
        args.source.type == .html && !isPreviewUnavailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if canPreviewHTML, !showsSource, let html = args.source.html {
                    htmlPreview(html)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            descriptionText
                            Divider()
                            contentBody
                            if hasFooter {
                                Divider()
                                footerText
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(args.title ?? "Artifact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canPreviewHTML {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(showsSource ? "Preview" : "Source") { showsSource.toggle() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var hasDescription: Bool {
        !(args.description ?? "").isEmpty
    }

    private var hasFooter: Bool {
        !(args.footer ?? "").isEmpty
    }

    @ViewBuilder
    private var descriptionText: some View {
        if let description = args.description, !description.isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
        }
    }

    @ViewBuilder
    private var footerText: some View {
        if let footer = args.footer, !footer.isEmpty {
            Text(footer)
                .font(.caption)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
        }
    }

    /// The web view scrolls the artifact itself, so the description and
    /// footer sit outside it rather than in a surrounding scroll view.
    private func htmlPreview(_ html: String) -> some View {
        VStack(spacing: 0) {
            if hasDescription {
                descriptionText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Divider()
            }
            ArtifactHTMLView(html: html) {
                isPreviewUnavailable = true
            }
            if hasFooter {
                Divider()
                footerText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch args.source.type {
        case .markdown:
            if let markdown = args.source.markdown {
                LaTeXMarkdownView(content: markdown, isDarkMode: isDarkMode)
                    .markdownStyleHost(isDarkMode: isDarkMode)
            }
        case .html:
            if isPreviewUnavailable {
                Text("Preview unavailable")
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
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
