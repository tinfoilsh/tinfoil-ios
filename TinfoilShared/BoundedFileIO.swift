import Darwin
import Foundation

enum BoundedFileIO {
    static let chunkSize = 64 * 1024

    enum Error: Swift.Error, LocalizedError, Equatable {
        case notRegularFile
        case fileTooLarge(size: Int64, maximum: Int64)
        case fileChanged
        case destinationExists
        case readFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .notRegularFile:
                return "Only regular files can be attached."
            case .fileTooLarge(let size, let maximum):
                let sizeMB = Double(size) / 1_048_576
                let maximumMB = maximum / 1_048_576
                return String(format: "File is too large (%.1f MB). Maximum is %d MB.", sizeMB, maximumMB)
            case .fileChanged:
                return "The file changed while it was being read. Try again."
            case .destinationExists:
                return "Could not create a secure staging file."
            case .readFailed:
                return "Could not read the file."
            case .writeFailed:
                return "Could not stage the file."
            }
        }
    }

    struct FileInfo: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
    }

    static func read(from sourceURL: URL, maximumBytes: Int64) throws -> Data {
        let descriptor = try openSource(sourceURL)
        defer { Darwin.close(descriptor) }

        let initial = try verifiedInfo(for: descriptor, at: sourceURL)
        try enforceLimit(initial.size, maximumBytes: maximumBytes)

        var data = Data()
        data.reserveCapacity(Int(initial.size))
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = try readChunk(from: descriptor, into: &buffer)
            guard bytesRead > 0 else { break }
            totalBytes += Int64(bytesRead)
            try enforceLimit(totalBytes, maximumBytes: maximumBytes)
            buffer.withUnsafeBytes { bytes in
                data.append(bytes.bindMemory(to: UInt8.self).baseAddress!, count: bytesRead)
            }
        }

        try verifyUnchanged(descriptor: descriptor, url: sourceURL, initial: initial, bytesRead: totalBytes)
        return data
    }

    @discardableResult
    static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int64,
        destinationAttributes: [FileAttributeKey: Any] = [:]
    ) throws -> Int64 {
        let sourceDescriptor = try openSource(sourceURL)
        defer { Darwin.close(sourceDescriptor) }

        let initial = try verifiedInfo(for: sourceDescriptor, at: sourceURL)
        try enforceLimit(initial.size, maximumBytes: maximumBytes)

        let destinationDescriptor = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            if errno == EEXIST { throw Error.destinationExists }
            throw Error.writeFailed
        }
        let destinationIdentity: FileInfo
        do {
            destinationIdentity = try descriptorInfo(destinationDescriptor)
            if !destinationAttributes.isEmpty {
                try FileManager.default.setAttributes(
                    destinationAttributes,
                    ofItemAtPath: destinationURL.path
                )
            }
        } catch {
            Darwin.close(destinationDescriptor)
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        var completed = false
        defer {
            Darwin.close(destinationDescriptor)
            if !completed {
                removeFileIfMatching(destinationURL, identity: destinationIdentity)
            }
        }

        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = try readChunk(from: sourceDescriptor, into: &buffer)
            guard bytesRead > 0 else { break }
            totalBytes += Int64(bytesRead)
            try enforceLimit(totalBytes, maximumBytes: maximumBytes)
            try writeChunk(buffer, count: bytesRead, to: destinationDescriptor)
        }

        try verifyUnchanged(descriptor: sourceDescriptor, url: sourceURL, initial: initial, bytesRead: totalBytes)
        let destinationInfo = try verifiedInfo(for: destinationDescriptor, at: destinationURL)
        guard destinationInfo.device == destinationIdentity.device,
              destinationInfo.inode == destinationIdentity.inode,
              destinationInfo.size == totalBytes else {
            throw Error.writeFailed
        }
        completed = true
        return totalBytes
    }

    static func size(of url: URL, maximumBytes: Int64) throws -> Int64 {
        let descriptor = try openSource(url)
        defer { Darwin.close(descriptor) }
        let info = try verifiedInfo(for: descriptor, at: url)
        try enforceLimit(info.size, maximumBytes: maximumBytes)
        return info.size
    }

    private static func openSource(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw Error.notRegularFile }
            throw Error.readFailed
        }
        return descriptor
    }

    private static func verifiedInfo(for descriptor: Int32, at url: URL) throws -> FileInfo {
        let descriptorInfo = try descriptorInfo(descriptor)
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0 else { throw Error.fileChanged }
        let pathInfo = try fileInfo(from: pathStatus)
        guard descriptorInfo.device == pathInfo.device, descriptorInfo.inode == pathInfo.inode else {
            throw Error.fileChanged
        }
        return descriptorInfo
    }

    private static func descriptorInfo(_ descriptor: Int32) throws -> FileInfo {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Error.readFailed }
        return try fileInfo(from: status)
    }

    private static func fileInfo(from status: stat) throws -> FileInfo {
        guard status.st_mode & S_IFMT == S_IFREG else { throw Error.notRegularFile }
        guard status.st_size >= 0 else { throw Error.readFailed }
        return FileInfo(device: status.st_dev, inode: status.st_ino, size: Int64(status.st_size))
    }

    private static func verifyUnchanged(
        descriptor: Int32,
        url: URL,
        initial: FileInfo,
        bytesRead: Int64
    ) throws {
        let final = try verifiedInfo(for: descriptor, at: url)
        guard final == initial, final.size == bytesRead else { throw Error.fileChanged }
    }

    private static func enforceLimit(_ size: Int64, maximumBytes: Int64) throws {
        guard size <= maximumBytes else {
            throw Error.fileTooLarge(size: size, maximum: maximumBytes)
        }
    }

    private static func removeFileIfMatching(_ url: URL, identity: FileInfo) {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              let current = try? fileInfo(from: status),
              current.device == identity.device,
              current.inode == identity.inode else {
            return
        }
        _ = unlink(url.path)
    }

    private static func readChunk(from descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
        while true {
            let result = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if result >= 0 { return result }
            if errno != EINTR { throw Error.readFailed }
        }
    }

    private static func writeChunk(_ buffer: [UInt8], count: Int, to descriptor: Int32) throws {
        var written = 0
        while written < count {
            let result = buffer.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), count - written)
            }
            if result > 0 {
                written += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw Error.writeFailed
            }
        }
    }
}
