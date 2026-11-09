import Foundation
import OSLog

/// The directory under Application Support where the app keeps each
/// account's chats and dictation. Backups leave it out: the chats are sealed
/// under a key that never leaves this device, so a copy restored on another
/// could not be opened, and dictation is kept only until it is transcribed.
enum DeviceDataDirectory {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Storage")
    private static let name = "tinfoil"

    /// The directory, made and kept out of backups when create is set. One
    /// that cannot be kept out of backups is still used.
    static func url(create: Bool) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
        var url = support.appendingPathComponent(name, isDirectory: true)
        guard create else { return url }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            logger.error("Failed to keep the app's data out of backups: \(error, privacy: .public)")
        }
        return url
    }
}
