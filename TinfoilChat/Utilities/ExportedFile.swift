import Foundation

/// A file saved for the share sheet: written into a directory of its own,
/// readable only while the device is unlocked, and removed once shared or,
/// failing that, at the next launch.
struct ExportedFile: Identifiable, Equatable {
    private static let exportDirectoryName = "tinfoil-file-exports"
    /// What a file is saved as when its own name names no file.
    private static let untitledFileName = "Untitled"
    /// The names a path keeps for a directory rather than a file in it.
    private static let directoryNames: Set<String> = ["", ".", "..", "/"]

    let url: URL

    var id: URL { url }

    static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(exportDirectoryName, isDirectory: true)
    }

    /// The name a file is saved under: the last component of the name it
    /// was given, so no name places the file outside its directory.
    static func fileName(_ name: String) -> String {
        let component = (name as NSString).lastPathComponent
        return directoryNames.contains(component) ? untitledFileName : component
    }

    static func write(_ data: Data, named name: String, in exportsDirectory: URL = exportsDirectory) throws -> ExportedFile {
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
        let url = directory.appendingPathComponent(fileName(name), isDirectory: false)
        try data.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        didFinish = true
        return ExportedFile(url: url)
    }

    /// Removes the file, with its directory.
    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Removes every file a share left behind.
    static func removeAll(in exportsDirectory: URL = exportsDirectory) throws {
        do {
            try FileManager.default.removeItem(at: exportsDirectory)
        } catch CocoaError.fileNoSuchFile {
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
        }
    }
}
