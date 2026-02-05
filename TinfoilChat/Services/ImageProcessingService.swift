//
//  ImageProcessingService.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation
import UIKit

final class ImageProcessingService {
    static let shared = ImageProcessingService()
    private init() {}

    enum ProcessingError: LocalizedError {
        case imageTooLarge(Int64)
        case encodingFailed
        case invalidImageData

        var errorDescription: String? {
            switch self {
            case .imageTooLarge(let size):
                let sizeMB = Double(size) / 1_048_576
                return String(format: "Image is too large (%.1f MB). Maximum is %d MB.", sizeMB, Constants.Attachments.maxImageSizeBytes / 1_048_576)
            case .encodingFailed:
                return "Could not encode the image."
            case .invalidImageData:
                return "The selected file is not a valid image."
            }
        }
    }

    struct ProcessedImage {
        let base64: String
        let thumbnailBase64: String
        let fileSize: Int64
    }

    func processImage(data: Data) async throws -> ProcessedImage {
        guard Int64(data.count) <= Constants.Attachments.maxImageSizeBytes else {
            throw ProcessingError.imageTooLarge(Int64(data.count))
        }

        return try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else {
                throw ProcessingError.invalidImageData
            }

            let scaled = self.scaleImage(image, maxDimension: Constants.Attachments.maxImageDimension)

            guard let jpegData = scaled.jpegData(compressionQuality: Constants.Attachments.imageCompressionQuality) else {
                throw ProcessingError.encodingFailed
            }

            let base64 = jpegData.base64EncodedString()

            let thumbnail = self.scaleImage(image, maxDimension: Constants.Attachments.previewThumbnailSize)
            guard let thumbnailData = thumbnail.jpegData(compressionQuality: 0.6) else {
                throw ProcessingError.encodingFailed
            }
            let thumbnailBase64 = thumbnailData.base64EncodedString()

            return ProcessedImage(
                base64: base64,
                thumbnailBase64: thumbnailBase64,
                fileSize: Int64(data.count)
            )
        }.value
    }

    private func scaleImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
