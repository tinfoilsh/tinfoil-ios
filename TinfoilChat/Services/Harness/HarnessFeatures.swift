import Foundation
import OSLog
import UIKit
import UniformTypeIdentifiers

private let featuresLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

// MARK: - Projects

/// A project as the harness answers with it, with its documents when opened.
struct ProjectView: Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String
    var systemInstructions: String
    var color: String?
    var createdAt: String?
    var updatedAt: String?
    var documents: [Components.Schemas.ProjectDocument]?
}

private struct ProjectListPage: Decodable {
    var projects: [Components.Schemas.Project]
    var nextCursor: String
}

private struct ProjectCreateRequest: Encodable {
    var id: String?
    var name: String
    var description: String?
    var systemInstructions: String?
    var color: Nullable<String>?
}

private struct ProjectUpdateRequest: Encodable {
    var id: String
    var name: String?
    var description: String?
    var systemInstructions: String?
    var color: Nullable<String>?
}

private struct ProjectDocumentDeleteRequest: Encodable {
    var projectId: String
    var documentId: String
}

private struct Deleted: Decodable {
    var deleted: Int
}

/// The projects the harness keeps for an account, and their documents.
@MainActor
enum HarnessProjects {
    static func list(_ account: HarnessAccount) async throws -> [Components.Schemas.Project] {
        var projects: [Components.Schemas.Project] = []
        var cursor: String?
        repeat {
            let page: ProjectListPage = try await account.post(.projectsList, ListRequest(cursor: cursor))
            projects.append(contentsOf: page.projects)
            cursor = page.nextCursor.isEmpty ? nil : page.nextCursor
        } while cursor != nil
        return projects
    }

    static func get(_ account: HarnessAccount, id: String) async throws -> ProjectView {
        try await account.post(.projectsGet, ThreadRequest(id: id))
    }

    static func create(_ account: HarnessAccount, name: String, description: String, systemInstructions: String, color: String?) async throws -> Components.Schemas.Project {
        try await account.post(.projectsCreate, ProjectCreateRequest(name: name, description: description, systemInstructions: systemInstructions, color: color.map(Nullable.value)))
    }

    static func update(_ account: HarnessAccount, id: String, name: String? = nil, description: String? = nil, systemInstructions: String? = nil, color: Nullable<String>? = nil) async throws -> Components.Schemas.Project {
        try await account.post(.projectsUpdate, ProjectUpdateRequest(id: id, name: name, description: description, systemInstructions: systemInstructions, color: color))
    }

    static func delete(_ account: HarnessAccount, id: String) async throws {
        let _: RawJSON = try await account.post(.projectsDelete, ThreadRequest(id: id))
    }

    @discardableResult
    static func deleteAll(_ account: HarnessAccount) async throws -> Int {
        let deleted: Deleted = try await account.post(.projectsDeleteAll)
        return deleted.deleted
    }

    static func uploadDocument(_ account: HarnessAccount, projectId: String, file: Data, fileName: String, mimeType: String) async throws -> Components.Schemas.ProjectDocument {
        let prepared = try await HarnessUploads.prepare(file, fileName: fileName, mimeType: mimeType, groups: account.session?.composer.projectDocuments ?? [])
        return try await account.upload(.projectDocumentUpload, file: prepared.data, fileName: fileName, mimeType: prepared.mimeType, fields: ["projectId": projectId])
    }

    static func deleteDocument(_ account: HarnessAccount, projectId: String, documentId: String) async throws {
        let _: RawJSON = try await account.post(.projectDocumentDelete, ProjectDocumentDeleteRequest(projectId: projectId, documentId: documentId))
    }
}

// MARK: - Search

/// A page of stored chats found: the chats, how many more match that cannot
/// be opened, and whether the index is still being built, so results may be
/// missing.
struct SearchPage: Decodable, Equatable, Sendable {
    var results: [ThreadSummary]
    var unreadable: Int
    var indexing: Bool
}

@MainActor
enum HarnessSearch {
    static func search(_ account: HarnessAccount, query: String) async throws -> SearchPage {
        try await account.post(.search, SearchRequest(query: query, limit: Constants.Harness.Search.resultLimit))
    }
}

// MARK: - Shares

private struct ShareStatus: Decodable {
    var shared: Bool?
}

private struct ShareThreadRequest: Encodable {
    var threadId: String
}

@MainActor
enum HarnessShares {
    static let tooLargeMessage = "This chat is too large to share. Fork the part you want to share from one of its messages, then share the fork."

    /// A share the harness or the share store refused for its size.
    static func isTooLarge(_ error: Error) -> Bool {
        guard let error = error as? HarnessError else { return false }
        return error.status == 413 || error.detail.status == 413 || error.code == HarnessErrorCode.threadTooLarge
    }

    /// Shares are keyed by the chat they share, so the owner can check and
    /// revoke one without its link, for stored and local chats alike.
    static func status(_ account: HarnessAccount, threadId: String) async throws -> Bool {
        let status: ShareStatus = try await account.post(.shareStatus, ShareThreadRequest(threadId: threadId), keyless: true)
        guard let shared = status.shared else {
            throw HarnessError(code: HarnessErrorCode.upstreamRefused, message: "The share status could not be read.", action: .retry)
        }
        return shared
    }

    static func revoke(_ account: HarnessAccount, threadId: String) async throws {
        let _: RawJSON = try await account.post(.shareRevoke, ShareThreadRequest(threadId: threadId), keyless: true)
    }
}

// MARK: - Transfers

/// A chat this device keeps, with the originals of its attachments.
struct DeviceChatCopy {
    var thread: StoredThread
    var originals: Originals
}

private struct TranscriptReply: Decodable {
    var thread: RawJSON?
    var revision: String?
}

/// Moving a chat between the cloud and this device keeps its id. A chat on
/// the device holds its attachments' content, so a move carries the content
/// with it.
@MainActor
enum HarnessTransfers {
    /// A run of the chat is still streaming, so moving it now would leave
    /// the reply behind.
    static var inFlight: HarnessError {
        HarnessError(code: HarnessErrorCode.runInFlight, message: "Wait for the reply to finish before moving this chat.", action: .retry, status: 409)
    }

    private static var alreadyOnDevice: HarnessError {
        HarnessError(code: HarnessErrorCode.threadExists, message: "This chat is already stored on this device.", action: .stop, status: 409)
    }

    /// A request the harness refused, or that failed before it was sent,
    /// changed nothing. A server error may come after the change committed,
    /// and so may a request whose connection failed.
    private static func isRefusal(_ error: Error) -> Bool {
        guard let error = error as? HarnessError, error.code != HarnessErrorCode.connection else { return false }
        return error.status == nil || error.status! < Constants.Harness.ChatAccess.serverErrorStatus
    }

    /// A stored chat as this device keeps it: the thread with every
    /// attachment's content inline.
    private static func cloudTranscript(_ account: HarnessAccount, threadId: String) async throws -> (thread: StoredThread, revision: String) {
        let reply: TranscriptReply = try await account.post(.transcript, ShareThreadRequest(threadId: threadId))
        guard let revision = reply.revision, !revision.isEmpty, let data = reply.thread?.data, var thread = StoredThread(data: data) else {
            throw HarnessError(code: HarnessErrorCode.upstreamRefused, message: "The chat service returned an invalid chat.", action: .retry)
        }
        thread.id = threadId
        return (thread, revision)
    }

    /// Stores a chat on this device, then deletes its cloud copy. A deletion
    /// that was refused leaves the cloud copy, so the device copy is removed
    /// again and the chat stays where it was. One that failed in any other
    /// way may have committed, so the device copy, perhaps the only one
    /// left, is kept.
    static func placeOnDevice(_ account: HarnessAccount, store: LocalThreadStore, thread: StoredThread, originals: Originals = [:], revision: String? = nil) async throws -> StoredThread {
        guard let saved = try await store.add(thread, originals: originals) else { throw alreadyOnDevice }
        do {
            let _: RawJSON = try await account.post(.delete, DeleteRequest(id: thread.id, revision: revision))
        } catch {
            guard isRefusal(error) else { throw error }
            do { try await store.delete(thread.id) } catch {
                featuresLogger.error("Failed to remove a chat copied to this device: \(error, privacy: .public)")
            }
            throw error
        }
        return saved
    }

    static func moveToDevice(_ account: HarnessAccount, store: LocalThreadStore, threadId: String) async throws -> StoredThread {
        let (thread, revision) = try await cloudTranscript(account, threadId: threadId)
        return try await placeOnDevice(account, store: store, thread: thread, revision: revision)
    }

    private static func deviceCopy(_ store: LocalThreadStore, threadId: String) async throws -> DeviceChatCopy {
        guard let thread = try await store.get(threadId) else {
            throw HarnessError(code: HarnessErrorCode.threadNotFound, message: "This chat is no longer stored on this device.", action: .stop, status: 404)
        }
        return DeviceChatCopy(thread: thread, originals: try await store.originals(threadId, attachmentIds: thread.attachments.map(\.id)))
    }

    /// Stores a chat from one store of this device in another under the same
    /// id, as a temporary chat the user keeps, then deletes it from the
    /// first.
    static func moveOnDevice(from: LocalThreadStore, to: LocalThreadStore, threadId: String) async throws -> StoredThread {
        let copy = try await deviceCopy(from, threadId: threadId)
        guard let saved = try await to.add(copy.thread, originals: copy.originals) else { throw alreadyOnDevice }
        try await from.delete(threadId)
        return saved
    }

    /// Stores a chat from this device in the cloud under the same id, then
    /// deletes it from the device. A failed import leaves the device copy as
    /// it was; when the device copy cannot be deleted, the cloud copy is
    /// deleted again. The device copy is returned, so a caller can put it
    /// back.
    static func moveToCloud(_ account: HarnessAccount, store: LocalThreadStore, threadId: String) async throws -> (summary: ThreadSummary, original: DeviceChatCopy) {
        let copy = try await deviceCopy(store, threadId: threadId)
        let summary: ThreadSummary = try await account.post(.threadImport, TransferRequest(threadId: threadId, thread: copy.thread))
        do {
            try await store.delete(threadId)
        } catch {
            do {
                let _: RawJSON = try await account.post(.delete, DeleteRequest(id: threadId))
            } catch {
                featuresLogger.error("Failed to remove a chat copied to the cloud: \(error, privacy: .public)")
            }
            throw error
        }
        return (summary, copy)
    }
}

// MARK: - Uploads

/// What a file picker offers and an upload is checked against: the file
/// groups the session's composer names.
enum HarnessUploads {
    /// A file of a type no group names uploads as text, which the harness
    /// reads when its contents are text.
    private static let textExtension = ".txt"
    static let imageQuality: CGFloat = 0.85

    struct Prepared {
        let data: Data
        let mimeType: String
    }

    private static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[dot...].lowercased()
    }

    /// A file's MIME type from its name, as an upload names it.
    static func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        if let type = UTType(filenameExtension: ext), let mimeType = type.preferredMIMEType { return mimeType }
        switch ext.lowercased() {
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }

    /// Refuses a picked file before it uploads: one larger than its group
    /// takes, or one of a type no group names when no group takes text.
    static func check(_ data: Data, fileName: String, groups: [Components.Schemas.FileGroup]) throws -> Components.Schemas.FileGroup {
        let ext = fileExtension(of: fileName)
        let group = (ext.isEmpty ? nil : groups.first { $0.accept.contains(ext) }) ?? groups.first { $0.accept.contains(textExtension) }
        guard let group else {
            throw HarnessError(code: "ATTACHMENT_UNSUPPORTED", message: "\(fileName) is not a supported file type.", action: .revise, status: 415)
        }
        guard data.count > group.maxBytes else { return group }
        let text = group.accept.contains(textExtension)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(group.maxBytes), countStyle: .file)
        throw HarnessError(
            code: "ATTACHMENT_TOO_LARGE",
            message: text ? "Text file exceeds the limit of \(limit)." : "File size exceeds the limit of \(limit).",
            action: .revise,
            status: 413
        )
    }

    /// The file as it uploads. Only an image's upload copy is scaled; text
    /// extraction and image descriptions belong to the harness.
    static func prepare(_ data: Data, fileName: String, mimeType: String, groups: [Components.Schemas.FileGroup]) async throws -> Prepared {
        let group = try check(data, fileName: fileName, groups: groups)
        guard let maxSide = group.imageMaxSide else { return Prepared(data: data, mimeType: mimeType) }
        return await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return Prepared(data: data, mimeType: mimeType) }
            let longest = max(image.size.width * image.scale, image.size.height * image.scale)
            let scale = min(1, CGFloat(maxSide) / longest)
            if scale == 1, mimeType == "image/jpeg" { return Prepared(data: data, mimeType: mimeType) }
            let size = CGSize(width: max(1, floor(image.size.width * image.scale * scale)), height: max(1, floor(image.size.height * image.scale * scale)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let jpeg = resized.jpegData(compressionQuality: imageQuality), jpeg.count <= group.maxBytes else {
                return Prepared(data: data, mimeType: mimeType)
            }
            return Prepared(data: jpeg, mimeType: "image/jpeg")
        }.value
    }

    private struct Uploaded: Decodable {
        let attachment: Components.Schemas.Attachment
    }

    /// Converts a file into an attachment the next turn sends.
    @MainActor
    static func upload(_ account: HarnessAccount, data: Data, fileName: String, mimeType: String) async throws -> Components.Schemas.Attachment {
        let prepared = try await prepare(data, fileName: fileName, mimeType: mimeType, groups: account.session?.composer.attachments ?? [])
        let uploaded: Uploaded = try await account.upload(.attachmentUpload, file: prepared.data, fileName: fileName, mimeType: prepared.mimeType, keyless: true)
        return uploaded.attachment
    }
}

// MARK: - Speech

private struct Transcription: Decodable {
    var text: String
}

@MainActor
enum HarnessSpeech {
    /// The words of a recording, as the harness transcribes it.
    static func transcribe(_ account: HarnessAccount, recording: Data, fileName: String, mimeType: String) async throws -> String {
        let transcription: Transcription = try await account.upload(.transcriptions, file: recording, fileName: fileName, mimeType: mimeType, keyless: true)
        return transcription.text
    }

    /// Reads a text aloud, as one stream of audio.
    static func speak(_ account: HarnessAccount, text: String) async throws -> HarnessResponse {
        try await account.stream(.speech, SpeechRequest(text: text), keyless: true)
    }
}

// MARK: - Metadata

/// A page's details as a preview shows them.
struct LinkPreview: Equatable, Sendable {
    var title: String?
    var description: String?
    var image: String?
    var siteName: String?

    /// A page's details as its widget stored them or they were read later.
    init(_ value: [String: Any]) {
        func trimmed(_ member: String) -> String? {
            let text = (value[member] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        title = trimmed("title")
        description = trimmed("description")
        siteName = trimmed("siteName")
        // An image shows only from a web address.
        if let image = trimmed("image"), let url = URL(string: image), ["http", "https"].contains(url.scheme ?? "") { self.image = image }
    }
}

private struct PageRequest: Encodable {
    var url: String
}

private struct FaviconReply: Decodable {
    var status: String
    var faviconBytes: String?
    var faviconContentType: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case faviconBytes = "favicon_bytes"
        case faviconContentType = "favicon_content_type"
    }
}

@MainActor
enum HarnessMetadata {
    /// A page's title, description, image and site name, which the harness
    /// reads inside the enclave.
    static func link(_ account: HarnessAccount, url: String) async throws -> LinkPreview {
        let reply: RawJSON = try await account.post(.linkMetadata, PageRequest(url: url), keyless: true)
        return LinkPreview((try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any] ?? [:])
    }

    /// A site's favicon, which the harness fetches inside the enclave; nil
    /// when the site has none, or its icon is not an image.
    static func favicon(_ account: HarnessAccount, url: String) async throws -> (data: Data, mimeType: String)? {
        let reply: FaviconReply = try await account.post(.favicon, PageRequest(url: url), keyless: true)
        guard reply.status == "found", let type = reply.faviconContentType, type.lowercased().hasPrefix("image/"),
              let bytes = reply.faviconBytes, let data = Data(base64Encoded: bytes) else { return nil }
        return (data, type)
    }
}
