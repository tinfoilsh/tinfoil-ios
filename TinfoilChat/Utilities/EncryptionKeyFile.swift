import Foundation

/// An encryption key saved as a PEM file for the share sheet: written into a
/// directory of its own, readable only while the device is unlocked, and
/// removed once shared or, failing that, at the next launch.
enum EncryptionKeyFile {
    private static let exportDirectoryName = "tinfoil-key-exports"
    private static let fileNamePrefix = "tinfoil-chat-key-"
    private static let fileExtension = "pem"
    private static let dateFormat = "yyyy-MM-dd"
    private static let dateLocale = "en_US_POSIX"
    private static let keyPrefix = "key_"

    static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(exportDirectoryName, isDirectory: true)
    }

    static func contents(for key: String) -> String {
        let keyContent = key.hasPrefix(keyPrefix) ? String(key.dropFirst(keyPrefix.count)) : key
        return """
        -----BEGIN TINFOIL CHAT ENCRYPTION KEY-----
        \(keyContent)
        -----END TINFOIL CHAT ENCRYPTION KEY-----
        """
    }

    static func write(key: String, date: Date = Date(), exportsDirectory: URL = exportsDirectory) throws -> URL {
        let directory = exportsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var didFinish = false
        defer {
            if !didFinish {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: dateLocale)
        let url = directory
            .appendingPathComponent(fileNamePrefix + formatter.string(from: date))
            .appendingPathExtension(fileExtension)
        try Data(contents(for: key).utf8).write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        didFinish = true
        return url
    }

    /// Removes a file `write` made, with its directory.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Removes every key file a share left behind.
    static func removeExports(in exportsDirectory: URL = exportsDirectory) throws {
        do {
            try FileManager.default.removeItem(at: exportsDirectory)
        } catch CocoaError.fileNoSuchFile {
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
        }
    }
}
