import Foundation
import VisionKit

/// Encodes scanned pages off the main actor, one at a time, without retaining
/// an array of full-resolution page images.
actor DocumentScanImageSource {
    private let scan: VNDocumentCameraScan

    init(scan: VNDocumentCameraScan) {
        self.scan = scan
    }

    func imageData(at index: Int) throws -> Data {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = scan.imageOfPage(at: index)
            guard let data = image.jpegData(compressionQuality: Constants.Attachments.imageCompressionQuality) else {
                throw ScanEncodingError()
            }
            return data
        }
    }
}

/// A scanned page that could not be encoded as a JPEG.
struct ScanEncodingError: LocalizedError {
    var errorDescription: String? { "The scanned page could not be encoded." }
}
