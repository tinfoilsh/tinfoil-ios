//
//  AttachmentModels.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation
import UIKit

enum AttachmentType: String, Codable, Equatable {
    case document
    case image
}

enum AttachmentProcessingState: String, Codable, Equatable {
    case pending
    case processing
    case completed
    case failed
}

func attachmentsAreReadyToSend(_ attachments: [Attachment]) -> Bool {
    attachments.allSatisfy { $0.processingState == .completed }
}

struct Attachment: Identifiable, Equatable {
    var id: String
    let type: AttachmentType
    let fileName: String
    var mimeType: String?
    var base64: String?
    var thumbnailBase64: String?
    var textContent: String?
    var description: String?
    var fileSize: Int64
    var sharedImportRequestID: UUID?
    // Per-attachment AES-256 key as standard base64 (32 raw bytes → 44 chars).
    // Cross-platform contract: iOS uses Data.base64EncodedString(), React uses btoa().
    // v2 attachments live in buckets and are addressed through the sync enclave
    // (`/v1/attachment/get` with this key as the slot key); legacy v0/v1 rows
    // were stored at controlplane's `/api/storage/attachment/:id` and are
    // migrated to v2 by the rewrap cascade.
    var encryptionKey: String?
    var processingState: AttachmentProcessingState

    init(
        id: String = UUID().uuidString.lowercased(),
        type: AttachmentType,
        fileName: String,
        mimeType: String? = nil,
        base64: String? = nil,
        thumbnailBase64: String? = nil,
        textContent: String? = nil,
        description: String? = nil,
        fileSize: Int64 = 0,
        sharedImportRequestID: UUID? = nil,
        encryptionKey: String? = nil,
        processingState: AttachmentProcessingState = .pending
    ) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.mimeType = mimeType
        self.base64 = base64
        self.thumbnailBase64 = thumbnailBase64
        self.textContent = textContent
        self.description = description
        self.fileSize = fileSize
        self.sharedImportRequestID = sharedImportRequestID
        self.encryptionKey = encryptionKey
        self.processingState = processingState
    }
}

// MARK: - Codable (exclude transient UI state from serialization)

extension Attachment: Codable {
    enum CodingKeys: String, CodingKey {
        case id, type, fileName, mimeType, base64, thumbnailBase64
        case textContent, description, fileSize
        case encryptionKey
        // Oldest chats serialized the per-attachment key under `key`.
        // Decode reads both; encode always writes `encryptionKey`.
        case key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        type = try container.decode(AttachmentType.self, forKey: .type)
        fileName = try container.decode(String.self, forKey: .fileName)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        base64 = try container.decodeIfPresent(String.self, forKey: .base64)
        thumbnailBase64 = try container.decodeIfPresent(String.self, forKey: .thumbnailBase64)
        textContent = try container.decodeIfPresent(String.self, forKey: .textContent)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        sharedImportRequestID = nil
        let modernKey = try container.decodeIfPresent(String.self, forKey: .encryptionKey)
        let legacyKey = try container.decodeIfPresent(String.self, forKey: .key)
        encryptionKey = modernKey ?? legacyKey
        // processingState is transient UI state — always reset to completed on decode
        processingState = .completed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(base64, forKey: .base64)
        try container.encodeIfPresent(thumbnailBase64, forKey: .thumbnailBase64)
        try container.encodeIfPresent(textContent, forKey: .textContent)
        try container.encodeIfPresent(description, forKey: .description)
        if fileSize > 0 {
            try container.encode(fileSize, forKey: .fileSize)
        }
        try container.encodeIfPresent(encryptionKey, forKey: .encryptionKey)
        // processingState is transient UI state — never encode
    }
}
