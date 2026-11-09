import Foundation
import Testing
@testable import TinfoilChat

@Suite("Device data directory")
struct DeviceDataDirectoryTests {
    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    /// The directory as an install from before it was kept out of backups
    /// left it.
    private func includeInBackups(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try url.setResourceValues(values)
    }

    @Test func keepsAnAccountsChatsAndDictationOutOfBackups() throws {
        let root = try DeviceDataDirectory.url(create: true).standardizedFileURL
        let userId = "backup-\(UUID().uuidString)"

        try includeInBackups(root)
        let chats = try DeviceThreadStore.directory(userId: userId)
        defer { try? FileManager.default.removeItem(at: chats) }
        #expect(try isExcludedFromBackup(root))

        try includeInBackups(root)
        let dictation = try DictationStore.directory(userId: userId, create: true)
        defer { try? FileManager.default.removeItem(at: dictation) }
        #expect(try isExcludedFromBackup(root))

        for directory in [chats, dictation] {
            #expect(directory.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent() == root)
        }
    }
}
