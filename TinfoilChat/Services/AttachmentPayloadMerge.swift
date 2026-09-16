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
    /// True for a synced image whose full-resolution bytes have not been
    /// fetched from the attachment bucket yet.
    static func isUnfetchedSyncedImage(_ attachment: Attachment) -> Bool {
        attachment.type == .image && attachment.base64 == nil && attachment.encryptionKey != nil
    }

    static func containsUnfetchedSyncedImages(_ messages: [Message]) -> Bool {
        messages.contains { message in
            message.attachments.contains(where: isUnfetchedSyncedImage)
        }
    }

    /// Returns `messages` with the given attachment-id → base64 map merged
    /// into matching attachments.
    static func applyingImageBytes(
        _ bytesById: [String: String],
        to messages: [Message]
    ) -> [Message] {
        var merged = messages
        for messageIndex in merged.indices {
            for attachmentIndex in merged[messageIndex].attachments.indices {
                let attachmentId = merged[messageIndex].attachments[attachmentIndex].id
                if let base64 = bytesById[attachmentId] {
                    merged[messageIndex].attachments[attachmentIndex].base64 = base64
                }
            }
        }
        return merged
    }

    /// Returns `incoming` with full-resolution image bytes copied from
    /// `existing` wherever the incoming attachment lacks them.
    ///
    /// Attachments are matched by id first. When the upload minted a new
    /// id for a locally created attachment, the fallback matches by
    /// metadata (type, file name, mime type, size) within the same
    /// message, as long as that metadata identifies a single attachment
    /// there.
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
                bytesByMetadata[MetadataKey(message: message, attachment: attachment), default: []]
                    .append(base64)
            }
        }
        guard !bytesById.isEmpty else { return incoming }

        var merged = incoming
        for messageIndex in merged.indices {
            let message = merged[messageIndex]
            for attachmentIndex in message.attachments.indices {
                let attachment = message.attachments[attachmentIndex]
                guard attachment.type == .image, attachment.base64 == nil else { continue }
                if let base64 = bytesById[attachment.id] {
                    merged[messageIndex].attachments[attachmentIndex].base64 = base64
                    continue
                }
                if let candidates = bytesByMetadata[MetadataKey(message: message, attachment: attachment)],
                   candidates.count == 1 {
                    merged[messageIndex].attachments[attachmentIndex].base64 = candidates[0]
                }
            }
        }
        return merged
    }

    private struct MetadataKey: Hashable {
        let messageId: String
        let type: AttachmentType
        let fileName: String
        let mimeType: String?
        let fileSize: Int64

        init(message: Message, attachment: Attachment) {
            messageId = message.id
            type = attachment.type
            fileName = attachment.fileName
            mimeType = attachment.mimeType
            fileSize = attachment.fileSize
        }
    }
}
