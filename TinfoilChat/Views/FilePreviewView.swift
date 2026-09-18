//
//  FilePreviewView.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI

enum FilePreviewKind: Equatable {
    case image
    case text
    case icon
}

enum FilePreviewClassifier {
    static func kind(filename: String, hasThumbnail: Bool, textContent: String?) -> FilePreviewKind {
        if hasThumbnail { return .image }
        if hasTextPreview(filename: filename, textContent: textContent) { return .text }
        return .icon
    }

    static func hasTextPreview(filename: String, textContent: String?) -> Bool {
        guard let textContent,
              !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        return Constants.FilePreview.textExtensions.contains(ext)
    }

    /// Trims a document down to the first few lines so the tile has something
    /// to lay out without holding the entire body in the view hierarchy.
    static func excerpt(_ content: String) -> String {
        // Only the head of the document is ever shown, so bound the work to a
        // prefix instead of scanning a possibly multi-megabyte body.
        let head = content.prefix(
            Constants.FilePreview.textMaxCharacters * Constants.FilePreview.textMaxLines
        )
        let lines = head
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", maxSplits: Constants.FilePreview.textMaxLines, omittingEmptySubsequences: false)
            .prefix(Constants.FilePreview.textMaxLines)
        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(Constants.FilePreview.textMaxCharacters))
    }

    static func iconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "html": return "globe"
        case "csv": return "tablecells"
        case "md": return "text.document"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "avif": return "photo"
        default: return "doc.text"
        }
    }
}

/// Thumbnail for a file: a real image for pictures, a miniature page of text
/// for plain-text documents (in the style of Finder document icons), and a
/// file-type glyph otherwise.
struct FilePreviewView: View {
    let filename: String
    var thumbnailBase64: String? = nil
    var textContent: String? = nil
    var size: CGFloat = Constants.FilePreview.projectRowSize
    /// Stable key for the decoded-image cache; defaults to the thumbnail hash.
    var cacheKey: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var kind: FilePreviewKind {
        FilePreviewClassifier.kind(
            filename: filename,
            hasThumbnail: thumbnailBase64?.isEmpty == false,
            textContent: textContent
        )
    }

    private var resolvedCacheKey: String {
        cacheKey ?? "file-preview-\(filename)-\(thumbnailBase64?.hashValue ?? 0)"
    }

    var body: some View {
        ZStack {
            switch kind {
            case .image:
                DecodedBase64ImageView(base64: thumbnailBase64, cacheKey: resolvedCacheKey) {
                    iconTile
                }
            case .text:
                textTile
            case .icon:
                iconTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Constants.FilePreview.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.FilePreview.cornerRadius)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .accessibilityHidden(true)
    }

    private var iconTile: some View {
        ZStack {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            Image(systemName: FilePreviewClassifier.iconName(for: filename))
                .font(.system(size: size * 0.45))
                .foregroundColor(.secondary)
        }
    }

    private var textTile: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white)
            Text(FilePreviewClassifier.excerpt(textContent ?? ""))
                .font(.system(size: Constants.FilePreview.textFontSize, design: .monospaced))
                .foregroundColor(Color(white: 0.3))
                .multilineTextAlignment(.leading)
                .lineLimit(Constants.FilePreview.textMaxLines)
                .padding(Constants.FilePreview.textPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
