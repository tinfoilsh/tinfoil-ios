//
//  SharePayloadBuilder.swift
//  TinfoilChat
//
//  Builds the data-only payload published by chat sharing.
//

import Foundation

struct ShareableChatData: Codable, Equatable {
    let v: Int
    let title: String
    let messages: [ShareableMessage]
    let createdAt: Double

    struct ShareableMessage: Codable, Equatable {
        let role: String
        let content: String
        let modelDisplayName: String?
        let documentContent: String?
        let documents: [ShareableDocument]?
        let timestamp: Double
        let thoughts: String?
        let thinkingDuration: Double?
        let isError: Bool?
        let attachments: [ShareableAttachment]?
        let timeline: [JSONValue]?
        let annotations: [Annotation]?
        let webSearch: ShareableWebSearchState?
        let webSearchBeforeThinking: Bool?
        let urlFetches: [ShareableURLFetch]?
    }

    struct ShareableDocument: Codable, Equatable {
        let name: String
    }

    struct ShareableAttachment: Codable, Equatable {
        let id: String
        let type: String
        let fileName: String
        let mimeType: String?
        let thumbnailBase64: String?
        let encryptionKey: String?
        let textContent: String?
        let description: String?
    }

    struct ShareableWebSearchState: Codable, Equatable {
        let query: String?
        let status: String
        let sources: [ShareableWebSearchSource]
        let reason: String?
    }

    struct ShareableWebSearchSource: Codable, Equatable {
        let title: String
        let url: String
    }

    struct ShareableURLFetch: Codable, Equatable {
        let id: String
        let url: String
        let status: String
    }
}

enum SharePayloadBuilder {
    static func build(
        messages: [Message],
        chatTitle: String?,
        chatCreatedAt: Date?,
        now: Date = Date()
    ) -> ShareableChatData {
        let title = chatTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Shared Chat"
        return ShareableChatData(
            v: ShareV2Contract.payloadVersion,
            title: title,
            messages: messages.map(buildMessage),
            createdAt: (chatCreatedAt ?? now).timeIntervalSince1970 * ShareV2Contract.millisecondsPerSecond
        )
    }

    static func encode(_ payload: ShareableChatData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func buildMessage(_ message: Message) -> ShareableChatData.ShareableMessage {
        let documentContent = message.attachments.compactMap { attachment -> String? in
            guard attachment.type == .document,
                  let textContent = attachment.textContent,
                  !textContent.isEmpty else { return nil }
            return "Document title: \(attachment.fileName)\nDocument contents:\n\(textContent)"
        }
            .joined(separator: "\n\n")

        let documents = message.attachments.isEmpty ? nil : message.attachments.map {
            ShareableChatData.ShareableDocument(name: $0.fileName)
        }
        let attachments = message.attachments.isEmpty ? nil : message.attachments.map {
            ShareableChatData.ShareableAttachment(
                id: $0.id,
                type: $0.type.rawValue,
                fileName: $0.fileName,
                mimeType: $0.mimeType,
                thumbnailBase64: $0.thumbnailBase64,
                encryptionKey: $0.encryptionKey,
                textContent: $0.textContent,
                description: $0.description
            )
        }
        let webSearch = message.webSearchState.map {
            ShareableChatData.ShareableWebSearchState(
                query: $0.query,
                status: $0.status.rawValue,
                sources: $0.sources.map {
                    ShareableChatData.ShareableWebSearchSource(title: $0.title, url: $0.url)
                },
                reason: $0.reason
            )
        }
        let urlFetches = message.urlFetches.isEmpty ? nil : message.urlFetches.map {
            ShareableChatData.ShareableURLFetch(id: $0.id, url: $0.url, status: $0.status.rawValue)
        }

        return ShareableChatData.ShareableMessage(
            role: message.role.rawValue,
            content: message.content,
            modelDisplayName: message.modelDisplayName,
            documentContent: documentContent.isEmpty ? nil : documentContent,
            documents: documents,
            timestamp: message.timestamp.timeIntervalSince1970 * ShareV2Contract.millisecondsPerSecond,
            thoughts: message.thoughts,
            thinkingDuration: message.thinkingDuration,
            isError: message.isError,
            attachments: attachments,
            timeline: message.timeline,
            annotations: message.annotations,
            webSearch: webSearch,
            webSearchBeforeThinking: message.webSearchBeforeThinking,
            urlFetches: urlFetches
        )
    }
}

struct ValidatedShareSeal: Equatable {
    let shareKey: String
    let ciphertext: Data
}

enum ShareV2Contract {
    static let payloadVersion = 1
    static let uploadFormatVersion = "1"
    static let shareKeyHexLength = 64
    static let millisecondsPerSecond: Double = 1_000
    private static let lowercaseHexCharacters = Set("0123456789abcdef")

    static func validate(_ response: EnclaveShareSealResponse) throws -> ValidatedShareSeal {
        guard response.ok else {
            throw ShareContractError.sealRejected
        }
        guard response.shareKey.count == shareKeyHexLength,
              response.shareKey.allSatisfy(lowercaseHexCharacters.contains) else {
            throw ShareContractError.invalidShareKey
        }
        guard !response.ciphertext.isEmpty,
              response.ciphertext.count.isMultiple(of: 4),
              let ciphertext = Data(base64Encoded: response.ciphertext),
              !ciphertext.isEmpty,
              ciphertext.base64EncodedString() == response.ciphertext else {
            throw ShareContractError.invalidCiphertext
        }
        return ValidatedShareSeal(shareKey: response.shareKey, ciphertext: ciphertext)
    }

    static func shareURL(chatId: String, shareKey: String) -> String {
        "\(Constants.Share.shareBaseURL)/share/\(chatId)#v2:\(shareKey)"
    }
}

enum ShareContractError: LocalizedError {
    case sealRejected
    case invalidShareKey
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .sealRejected:
            return "Share seal was rejected"
        case .invalidShareKey:
            return "Share seal returned an invalid key"
        case .invalidCiphertext:
            return "Share seal returned invalid ciphertext"
        }
    }
}
