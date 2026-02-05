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

struct Attachment: Identifiable, Codable, Equatable {
    let id: String
    let type: AttachmentType
    let fileName: String
    var documentContent: String?
    var imageBase64: String?
    var thumbnailBase64: String?
    var fileSize: Int64
    var processingState: AttachmentProcessingState

    init(
        id: String = UUID().uuidString,
        type: AttachmentType,
        fileName: String,
        documentContent: String? = nil,
        imageBase64: String? = nil,
        thumbnailBase64: String? = nil,
        fileSize: Int64 = 0,
        processingState: AttachmentProcessingState = .pending
    ) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.documentContent = documentContent
        self.imageBase64 = imageBase64
        self.thumbnailBase64 = thumbnailBase64
        self.fileSize = fileSize
        self.processingState = processingState
    }
}
