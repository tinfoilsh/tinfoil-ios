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

/// An attachment as the views show it, from one the chat service holds or
/// one it is converting for the next turn.
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
        self.processingState = processingState
    }
}
