import Darwin
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
    private static let chunkSize = 64 * 1_024

    private struct OpenFile {
        let handle: FileHandle
        let device: dev_t
        let inode: ino_t
        let expectedSize: Int64
    }

    static func validatedSize(of url: URL, maximumSize: Int64) throws -> Int64 {
        guard maximumSize >= 0 else {
            throw BoundedFileIOError.invalidFile
        }
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
        let source = try openSource(at: url, maximumSize: maximumSize)
        defer { try? source.handle.close() }

        var data = Data()
        let size = try stream(maximumSize: maximumSize) { requestedCount in
            try source.handle.read(upToCount: requestedCount)
        } consume: { chunk in
            data.append(chunk)
        }
        try verify(source, at: url, streamedSize: size)
        return data
    }

    @discardableResult
    static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumSize: Int64,
        destinationAttributes: [FileAttributeKey: Any] = [:]
    ) throws -> Int64 {
        let source = try openSource(at: sourceURL, maximumSize: maximumSize)
        defer { try? source.handle.close() }

        var destinationHandle: FileHandle?
        var ownsDestination = false
        do {
            let descriptor = Darwin.open(
                destinationURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw BoundedFileIOError.invalidFile
            }
            ownsDestination = true
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            destinationHandle = handle
            if !destinationAttributes.isEmpty {
                try FileManager.default.setAttributes(
                    destinationAttributes,
                    ofItemAtPath: destinationURL.path
                )
            }

            let size = try stream(maximumSize: maximumSize) { requestedCount in
                try source.handle.read(upToCount: requestedCount)
            } consume: { chunk in
                try handle.write(contentsOf: chunk)
            }
            try verify(source, at: sourceURL, streamedSize: size)
            try handle.synchronize()
            try handle.close()
            destinationHandle = nil

            guard try validatedSize(of: destinationURL, maximumSize: maximumSize) == size else {
                throw BoundedFileIOError.invalidFile
            }
            return size
        } catch {
            try? destinationHandle?.close()
            if ownsDestination {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw error
        }
    }

    @discardableResult
    static func stream(
        maximumSize: Int64,
        readChunk: (Int) throws -> Data?,
        consume: (Data) throws -> Void
    ) throws -> Int64 {
        guard maximumSize >= 0 else {
            throw BoundedFileIOError.invalidFile
        }
        var totalSize: Int64 = 0
        while true {
            try Task<Never, Never>.checkCancellation()
            let remaining = maximumSize - totalSize
            let requestedCount = remaining >= Int64(chunkSize)
                ? chunkSize
                : Int(remaining) + 1
            guard let chunk = try readChunk(requestedCount), !chunk.isEmpty else {
                return totalSize
            }
            let nextSize = totalSize + Int64(chunk.count)
            guard nextSize <= maximumSize else {
                throw BoundedFileIOError.fileTooLarge(size: nextSize, maximum: maximumSize)
            }
            try Task<Never, Never>.checkCancellation()
            try consume(chunk)
            totalSize = nextSize
        }
    }

    private static func openSource(at url: URL, maximumSize: Int64) throws -> OpenFile {
        let expectedSize = try validatedSize(of: url, maximumSize: maximumSize)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw BoundedFileIOError.invalidFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  Int64(status.st_size) == expectedSize else {
                throw BoundedFileIOError.invalidFile
            }
            try verifyPath(at: url, device: status.st_dev, inode: status.st_ino)
            return OpenFile(
                handle: handle,
                device: status.st_dev,
                inode: status.st_ino,
                expectedSize: expectedSize
            )
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func verify(_ file: OpenFile, at url: URL, streamedSize: Int64) throws {
        var status = stat()
        guard fstat(file.handle.fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_dev == file.device,
              status.st_ino == file.inode,
              Int64(status.st_size) == file.expectedSize,
              streamedSize == file.expectedSize else {
            throw BoundedFileIOError.invalidFile
        }
        try verifyPath(at: url, device: file.device, inode: file.inode)
    }

    private static func verifyPath(at url: URL, device: dev_t, inode: ino_t) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_dev == device,
              status.st_ino == inode else {
            throw BoundedFileIOError.invalidFile
        }
    }
}
