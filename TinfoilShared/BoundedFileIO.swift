import Foundation

enum BoundedFileIOError: LocalizedError {
    case invalidFile
    case fileTooLarge(size: Int64, maximum: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "The file could not be read safely."
        case .fileTooLarge(let size, let maximum):
            return "The file is too large (\(size) bytes). Maximum is \(maximum) bytes."
        }
    }
}

struct BoundedFileIO {
    static func validatedSize(of url: URL, maximumSize: Int64) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize else {
            throw BoundedFileIOError.invalidFile
        }
        let size = Int64(fileSize)
        guard size <= maximumSize else {
            throw BoundedFileIOError.fileTooLarge(size: size, maximum: maximumSize)
        }
        return size
    }

    static func read(from url: URL, maximumSize: Int64) throws -> Data {
        let expectedSize = try validatedSize(of: url, maximumSize: maximumSize)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) <= maximumSize,
              Int64(data.count) == expectedSize,
              try validatedSize(of: url, maximumSize: maximumSize) == expectedSize else {
            throw BoundedFileIOError.invalidFile
        }
        return data
    }

    @discardableResult
    static func copy(from sourceURL: URL, to destinationURL: URL, maximumSize: Int64) throws -> Int64 {
        let expectedSize = try validatedSize(of: sourceURL, maximumSize: maximumSize)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        let copiedSize = try validatedSize(of: destinationURL, maximumSize: maximumSize)
        guard copiedSize == expectedSize,
              try validatedSize(of: sourceURL, maximumSize: maximumSize) == expectedSize else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw BoundedFileIOError.invalidFile
        }
        return copiedSize
    }
}
