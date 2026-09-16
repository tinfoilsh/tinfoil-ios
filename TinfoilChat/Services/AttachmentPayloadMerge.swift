//
//  AttachmentPayloadMerge.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.

import Foundation

/// Cloud copies of a chat carry image thumbnails and per-attachment keys
/// but never the full-resolution bytes, which are uploaded to the
/// attachment bucket separately. Applying such a copy over a local file
/// that still holds the bytes must not discard them, otherwise the next
/// request built from the chat sends a vision model an image-less prompt.
enum AttachmentPayloadMerge {
    /// Returns `incoming` with full-resolution image bytes copied from
    /// `existing` wherever the incoming attachment lacks them.
    ///
    /// Attachments are matched by id first. When the upload minted a new
    /// id for a locally created attachment, the metadata fallback
    /// (type, file name, mime type, size) matches the pre-upload copy as
    /// long as that metadata identifies a single local attachment.
    static func inheritingImageBytes(
        into incoming: [Message],
        from existing: [Message]
    ) -> [Message] {
        var bytesById: [String: String] = [:]
        var bytesByMetadata: [MetadataKey: [String]] = [:]
        for message in existing {
            for attachment in message.attachments {
                guard attachment.type == .image, let base64 = attachment.base64 else {
                    continue
                }
                bytesById[attachment.id] = base64
                bytesByMetadata[MetadataKey(attachment), default: []].append(base64)
            }
        }
        guard !bytesById.isEmpty else { return incoming }

        var merged = incoming
        for messageIndex in merged.indices {
            for attachmentIndex in merged[messageIndex].attachments.indices {
                let attachment = merged[messageIndex].attachments[attachmentIndex]
                guard attachment.type == .image, attachment.base64 == nil else { continue }
                if let base64 = bytesById[attachment.id] {
                    merged[messageIndex].attachments[attachmentIndex].base64 = base64
                    continue
                }
                if let candidates = bytesByMetadata[MetadataKey(attachment)],
                   candidates.count == 1 {
                    merged[messageIndex].attachments[attachmentIndex].base64 = candidates[0]
                }
            }
        }
        return merged
    }

    private struct MetadataKey: Hashable {
        let type: AttachmentType
        let fileName: String
        let mimeType: String?
        let fileSize: Int64

        init(_ attachment: Attachment) {
            type = attachment.type
            fileName = attachment.fileName
            mimeType = attachment.mimeType
            fileSize = attachment.fileSize
        }
    }
}
