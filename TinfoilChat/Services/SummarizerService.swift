//
//  SummarizerService.swift
//  TinfoilChat
//
//  Service for making requests to the summarizer enclave via EnclaveHandle
//

import Foundation
import TinfoilAI

/// Service for communicating with the Tinfoil summarizer enclave
actor SummarizerService {
    static let shared = SummarizerService()

    private var handle: EnclaveHandle?

    private init() {}

    /// The summarizer enclave's handle, which verifies on first use and again
    /// whenever its attestation expires
    private func enclaveHandle() throws -> EnclaveHandle {
        if let handle {
            return handle
        }
        let created = try EnclaveHandle.enclave(
            at: Constants.Summarizer.enclaveURL,
            repo: Constants.Summarizer.configRepo
        )
        handle = created
        return created
    }

    /// Summarize content using the summarizer enclave
    /// - Parameters:
    ///   - content: The text content to summarize
    ///   - style: The summarization style to use
    /// - Returns: The generated summary string
    func summarize(content: String, style: SummarizeStyle) async throws -> String {
        let enclave = try enclaveHandle()

        let request = SummarizeRequest(content: content, style: style)
        let requestData = try JSONEncoder().encode(request)

        let (data, response) = try await enclave.post(
            url: "\(Constants.Summarizer.enclaveURL)/summarize",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )

        guard response.statusCode == 200 else {
            throw SummarizerError.requestFailed(statusCode: response.statusCode)
        }

        let decoded = try JSONDecoder().decode(SummarizeResponse.self, from: data)
        return decoded.summary
    }

    func generateChatTitle(from messages: [Message]) async -> String? {
        guard let assistantMessage = messages.first(where: { $0.role == .assistant }),
              !assistantMessage.content.isEmpty else {
            return nil
        }

        let truncatedContent = assistantMessage.content
            .split(whereSeparator: \.isWhitespace)
            .prefix(Constants.TitleGeneration.wordThreshold)
            .joined(separator: " ")
        guard !truncatedContent.isEmpty else { return nil }

        guard let title = try? await summarize(
            content: truncatedContent,
            style: .titleSummary
        ), !title.isEmpty else {
            return nil
        }
        return title
    }
}

// MARK: - Models

enum SummarizeStyle: String, Codable {
    case `default`
    case thoughtsSummary = "thoughts_summary"
    case titleSummary = "title_summary"
}

private struct SummarizeRequest: Codable {
    let content: String
    let style: SummarizeStyle
}

private struct SummarizeResponse: Codable {
    let summary: String
}

enum SummarizerError: LocalizedError {
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode):
            return "Summarize request failed with status: \(statusCode)"
        }
    }
}
