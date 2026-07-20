//
//  MessageQueueView.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.
//
//  Shows messages queued while the assistant is responding, above the
//  input area. Mirrors the webapp's MessageQueue component.

import SwiftUI

struct MessageQueueView: View {
    let queue: [QueuedMessage]
    let isDarkMode: Bool
    let onRemove: (String) -> Void

    var body: some View {
        if !queue.isEmpty {
            VStack(spacing: 6) {
                ForEach(queue) { item in
                    QueuedMessageRow(item: item, isDarkMode: isDarkMode, onRemove: onRemove)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}

private struct QueuedMessageRow: View {
    let item: QueuedMessage
    let isDarkMode: Bool
    let onRemove: (String) -> Void

    private var previewText: String {
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > Constants.MessageQueue.previewMaxLength {
            return String(trimmed.prefix(Constants.MessageQueue.previewMaxLength)) + "…"
        }
        return trimmed
    }

    private var fallbackLabel: String {
        let attachmentCount = item.attachments.count
        if attachmentCount > 0 {
            return "\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")"
        }
        return "Queued message"
    }

    /// Single source of truth for whether an attachment renders as a
    /// thumbnail; everything else is listed by name instead.
    private func hasImagePreview(_ attachment: Attachment) -> Bool {
        attachment.type == .image && (attachment.thumbnailBase64 ?? attachment.base64) != nil
    }

    private var imageAttachments: [Attachment] {
        item.attachments.filter(hasImagePreview)
    }

    /// Attachments that can't be shown as a thumbnail (documents, or images
    /// without preview data). Listed by name so the queued payload stays
    /// verifiable even when the row also has preview text.
    private var namedAttachments: [Attachment] {
        item.attachments.filter { !hasImagePreview($0) }
    }

    private var thumbnailStrip: some View {
        HStack(spacing: 6) {
            ForEach(imageAttachments) { attachment in
                QueuedImageThumbnail(attachment: attachment, isDarkMode: isDarkMode)
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                if !imageAttachments.isEmpty {
                    // Hug the thumbnails when they fit; scroll on overflow.
                    ViewThatFits(in: .horizontal) {
                        thumbnailStrip
                        ScrollView(.horizontal, showsIndicators: false) {
                            thumbnailStrip
                        }
                    }
                }
                ForEach(namedAttachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                        Text(attachment.fileName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundColor(.secondary)
                }
                if !previewText.isEmpty || item.attachments.isEmpty {
                    Text(previewText.isEmpty ? fallbackLabel : previewText)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(Constants.MessageQueue.previewLineLimit)
                }
            }

            Button {
                onRemove(item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    // Lays out at one text line's height so the compact row
                    // isn't inflated; the hit area alone grows to the 44pt
                    // minimum via the inset content shape.
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle().inset(by: -12))
            }
            .accessibilityLabel("Remove queued message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.chatSurface(isDarkMode: isDarkMode))
        )
        // Sizes like a user bubble: hugs the text and caps at the same
        // adaptive width, trailing-aligned above the input.
        .modifier(MessageBubbleModifier(isUserMessage: true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued message: \(previewText.isEmpty ? fallbackLabel : previewText)")
    }
}

private struct QueuedImageThumbnail: View {
    let attachment: Attachment
    let isDarkMode: Bool

    private var previewBase64: String? {
        attachment.thumbnailBase64 ?? attachment.base64
    }

    var body: some View {
        DecodedBase64ImageView(
            base64: previewBase64,
            cacheKey: "queued-message-\(attachment.id)-\(previewBase64?.hashValue ?? 0)"
        ) {
            RoundedRectangle(cornerRadius: 8)
                .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        }
        .frame(
            width: Constants.MessageQueue.imageThumbnailSize,
            height: Constants.MessageQueue.imageThumbnailSize
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(attachment.fileName)
    }
}
