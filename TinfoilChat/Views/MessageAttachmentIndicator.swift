//
//  MessageAttachmentIndicator.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

struct MessageAttachmentIndicator: View {
    let attachments: [Attachment]
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(attachments) { attachment in
                AttachmentChip(attachment: attachment, isDarkMode: isDarkMode)
            }
        }
        .padding(.bottom, 4)
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 6) {
            if attachment.type == .image, let base64 = attachment.thumbnailBase64,
               let data = Data(base64Encoded: base64),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
            }

            Text(attachment.fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isDarkMode ? .white.opacity(0.8) : .black.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        )
    }

    private var iconName: String {
        let ext = (attachment.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "html": return "globe"
        case "csv": return "tablecells"
        case "md": return "text.document"
        default: return "doc.text"
        }
    }
}
