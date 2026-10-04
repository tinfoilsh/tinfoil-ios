import Foundation

struct DocumentPage: Codable, Equatable, Sendable {
    let page: Int
    let text: String
    let image: String
    let isScanned: Bool

    enum CodingKeys: String, CodingKey {
        case page, text, image
        case isScanned = "is_scanned"
    }

    init(page: Int, text: String, image: String = "", isScanned: Bool) {
        self.page = page
        self.text = text
        self.image = image
        self.isScanned = isScanned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decode(Int.self, forKey: .page)
        text = try container.decode(String.self, forKey: .text)
        image = container.contains(.image) ? try container.decode(String.self, forKey: .image) : ""
        isScanned = try container.decode(Bool.self, forKey: .isScanned)
        guard isValid else { throw DocumentAttachmentError.invalidPayload }
    }

    var isValid: Bool { page >= 0 && (!isScanned || !image.isEmpty) }

    var imageDataURL: String {
        "data:\(Constants.Attachments.scannedDocumentPageMimeType);base64,\(image)"
    }
}

enum DocumentAttachmentError: LocalizedError, Equatable {
    case invalidPayload
    case unavailable
    case syncDisabled
    case visionModelRequired

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Document content is invalid. Please reattach the document before continuing."
        case .unavailable:
            return "Document content could not be loaded. Please retry before continuing."
        case .syncDisabled:
            return "Document content is not on this device. Enable cloud sync to download it, then retry."
        case .visionModelRequired:
            return "This scanned document has no extracted text. Select an image-capable model to read it."
        }
    }
}

/// The document blob wire format shared with the webapp. Names and other
/// attachment metadata remain in the encrypted chat, not in this payload.
struct DocumentAttachmentPayload: Codable, Equatable, Sendable {
    let textContent: String?
    let pages: [DocumentPage]?

    enum CodingKeys: String, CodingKey { case textContent, pages }

    init(textContent: String? = nil, pages: [DocumentPage]? = nil) throws {
        self.textContent = textContent
        self.pages = pages
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textContent = container.contains(.textContent)
            ? try container.decode(String.self, forKey: .textContent) : nil
        pages = container.contains(.pages)
            ? try container.decode([DocumentPage].self, forKey: .pages) : nil
        try validate()
    }

    private func validate() throws {
        guard textContent != nil || pages != nil,
              pages?.allSatisfy(\.isValid) != false else {
            throw DocumentAttachmentError.invalidPayload
        }
    }

    static func hasInlineContent(_ attachment: Attachment) -> Bool {
        attachment.type == .document && (attachment.textContent != nil || attachment.pages != nil)
    }

    static func isOffloaded(_ attachment: Attachment) -> Bool {
        attachment.type == .document && !hasInlineContent(attachment)
            && attachment.encryptionKey?.isEmpty == false
    }

    static func containsOffloadedDocuments(_ messages: [Message]) -> Bool {
        messages.contains { $0.attachments.contains(where: isOffloaded) }
    }

    static func encode(_ attachment: Attachment) throws -> Data {
        let payload = try Self(textContent: attachment.textContent, pages: attachment.pages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    static func hydrate(
        _ messages: [Message],
        load: (Attachment) async throws -> Data
    ) async throws -> [Message] {
        var hydrated = messages
        for messageIndex in hydrated.indices {
            for attachmentIndex in hydrated[messageIndex].attachments.indices {
                try Task.checkCancellation()
                let attachment = hydrated[messageIndex].attachments[attachmentIndex]
                guard attachment.type == .document else { continue }
                if hasInlineContent(attachment) {
                    _ = try Self(textContent: attachment.textContent, pages: attachment.pages)
                    continue
                }
                guard isOffloaded(attachment) else { throw DocumentAttachmentError.unavailable }
                let bytes = try await load(attachment)
                try Task.checkCancellation()
                let payload = try JSONDecoder().decode(Self.self, from: bytes)
                hydrated[messageIndex].attachments[attachmentIndex].textContent = payload.textContent
                hydrated[messageIndex].attachments[attachmentIndex].pages = payload.pages
            }
        }
        return hydrated
    }

    static func merging(_ hydrated: [Message], into messages: [Message]) -> [Message] {
        let byId = Dictionary(
            hydrated.flatMap(\.attachments).filter(hasInlineContent).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = messages
        for messageIndex in result.indices {
            for attachmentIndex in result[messageIndex].attachments.indices {
                let attachment = result[messageIndex].attachments[attachmentIndex]
                guard isOffloaded(attachment), let source = byId[attachment.id],
                      source.encryptionKey == attachment.encryptionKey else { continue }
                result[messageIndex].attachments[attachmentIndex].textContent = source.textContent
                result[messageIndex].attachments[attachmentIndex].pages = source.pages
            }
        }
        return result
    }

    static func promptText(_ attachment: Attachment) -> String? {
        if let text = attachment.textContent, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        guard let pages = attachment.pages else { return attachment.textContent }
        return pages.map(\.text).joined(separator: "\n\n")
    }

    static func scannedPages(_ attachment: Attachment) -> [DocumentPage] {
        attachment.pages?.filter(\.isScanned) ?? []
    }

    static func requiresVision(_ attachment: Attachment) -> Bool {
        attachment.type == .document && !scannedPages(attachment).isEmpty
            && (promptText(attachment)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
