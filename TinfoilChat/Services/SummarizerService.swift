//
//  SummarizerService.swift
//  TinfoilChat
//
//  Service for making requests to the summarizer enclave via SecureClient
//

import Foundation
import TinfoilAI

/// Service for communicating with the Tinfoil summarizer enclave
actor SummarizerService {
    static let shared = SummarizerService()

    private var client: SecureClient?
    private var verificationTask: Task<SecureClient, Error>?

    private init() {}

    private func getClient() async throws -> SecureClient {
        if let client = client {
            return client
        }

        if let existingTask = verificationTask {
            return try await existingTask.value
        }

        let task = Task<SecureClient, Error> {
            let newClient = SecureClient(
                githubRepo: Constants.Summarizer.configRepo,
                enclaveURL: Constants.Summarizer.enclaveURL
            )
            _ = try await newClient.verify()
            return newClient
        }
        verificationTask = task

        do {
            let verifiedClient = try await task.value
            client = verifiedClient
            verificationTask = nil
            return verifiedClient
        } catch {
            verificationTask = nil
            throw error
        }
    }

    /// Summarize content using the summarizer enclave
    /// - Parameters:
    ///   - content: The text content to summarize
    ///   - style: The summarization style to use
    /// - Returns: The generated summary string
    func summarize(content: String, style: SummarizeStyle) async throws -> String {
        let client = try await getClient()

        let request = SummarizeRequest(content: content, style: style)
        let requestData = try JSONEncoder().encode(request)

        let response = try await client.post(
            url: "\(Constants.Summarizer.enclaveURL)/summarize",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )

        guard response.statusCode == 200 else {
            throw SummarizerError.requestFailed(statusCode: response.statusCode)
        }

        let decoded = try JSONDecoder().decode(SummarizeResponse.self, from: response.body)
        return decoded.summary
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
