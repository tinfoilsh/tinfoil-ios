//
//  SummarizerService.swift
//  TinfoilChat
//
//  Service for making requests to the summarizer enclave via SecureClient
//

import Foundation
import TinfoilAI

actor SummarizerRequestCoordinator {
    struct Permit: Sendable {
        let isHalfOpenProbe: Bool
        let generation: Int
        let requestID: Int
    }

    private let maximumConcurrentRequests: Int
    private let breakerDelays: [TimeInterval]
    private let maximumBreakerDelay: TimeInterval
    private var activeRequests = 0
    private var consecutiveFailures = 0
    private var openUntil: Date?
    private var halfOpenProbeInFlight = false
    private var generation = 0
    private var nextRequestID = 0
    private var latestResolvedRequestID = 0

    init(
        maximumConcurrentRequests: Int = Constants.Summarizer.maximumConcurrentRequests,
        breakerDelays: [TimeInterval] = Constants.Summarizer.breakerDelays,
        maximumBreakerDelay: TimeInterval = Constants.Summarizer.maximumBreakerDelay
    ) {
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.breakerDelays = breakerDelays
        self.maximumBreakerDelay = maximumBreakerDelay
    }

    func acquire(now: Date = Date()) throws -> Permit {
        let isHalfOpenProbe: Bool
        if let openUntil {
            guard now >= openUntil, !halfOpenProbeInFlight else {
                throw SummarizerError.temporarilyUnavailable
            }
            halfOpenProbeInFlight = true
            isHalfOpenProbe = true
        } else {
            isHalfOpenProbe = false
        }
        guard activeRequests < maximumConcurrentRequests else {
            if isHalfOpenProbe { halfOpenProbeInFlight = false }
            throw SummarizerError.busy
        }
        activeRequests += 1
        nextRequestID += 1
        return Permit(
            isHalfOpenProbe: isHalfOpenProbe,
            generation: generation,
            requestID: nextRequestID
        )
    }

    func finish(_ permit: Permit, error: Error?, now: Date = Date()) {
        guard permit.generation == generation else { return }
        activeRequests = max(0, activeRequests - 1)
        if permit.isHalfOpenProbe { halfOpenProbeInFlight = false }
        guard permit.requestID > latestResolvedRequestID else { return }
        latestResolvedRequestID = permit.requestID
        guard let error else {
            if permit.isHalfOpenProbe || openUntil == nil {
                consecutiveFailures = 0
                openUntil = nil
            }
            return
        }
        guard SummarizerService.isTransient(error) else {
            if permit.isHalfOpenProbe {
                consecutiveFailures = 0
                openUntil = nil
            } else if openUntil == nil {
                consecutiveFailures = 0
            }
            return
        }
        consecutiveFailures += 1
        let delay = breakerDelay(for: consecutiveFailures)
        openUntil = now.addingTimeInterval(delay)
    }

    func reset() {
        generation += 1
        activeRequests = 0
        consecutiveFailures = 0
        openUntil = nil
        halfOpenProbeInFlight = false
        nextRequestID = 0
        latestResolvedRequestID = 0
    }

    private func breakerDelay(for failureCount: Int) -> TimeInterval {
        guard !breakerDelays.isEmpty else { return maximumBreakerDelay }
        if failureCount <= breakerDelays.count {
            return min(breakerDelays[failureCount - 1], maximumBreakerDelay)
        }
        let extraFailures = failureCount - breakerDelays.count
        return min(
            breakerDelays[breakerDelays.count - 1] * pow(2, Double(extraFailures)),
            maximumBreakerDelay
        )
    }
}

/// Service for communicating with the Tinfoil summarizer enclave
actor SummarizerService {
    static let shared = SummarizerService()
    static let coordinator = SummarizerRequestCoordinator()

    private var client: SecureClient?
    private var verificationTask: Task<SecureClient, Error>?
    private var lifecycleGeneration = 0

    private init() {}

    func reset() async {
        lifecycleGeneration += 1
        verificationTask?.cancel()
        verificationTask = nil
        client = nil
        await Self.coordinator.reset()
    }

    private func getClient() async throws -> SecureClient {
        if let client { return client }
        if let verificationTask { return try await verificationTask.value }

        let generation = lifecycleGeneration
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
            guard generation == lifecycleGeneration else { throw CancellationError() }
            client = verifiedClient
            verificationTask = nil
            return verifiedClient
        } catch {
            if generation == lifecycleGeneration {
                verificationTask = nil
            }
            throw error
        }
    }

    /// Summarize content using the summarizer enclave
    /// - Parameters:
    ///   - content: The text content to summarize
    ///   - style: The summarization style to use
    /// - Returns: The generated summary string
    func summarize(content: String, style: SummarizeStyle) async throws -> String {
        let permit = try await Self.coordinator.acquire()
        let generation = lifecycleGeneration
        do {
            let client = try await getClient()
            let requestData = try JSONEncoder().encode(SummarizeRequest(content: content, style: style))
            let response = try await client.post(
                url: "\(Constants.Summarizer.enclaveURL)/summarize",
                headers: ["Content-Type": "application/json"],
                body: requestData
            )
            guard response.statusCode == 200 else {
                throw Self.parseError(statusCode: response.statusCode, body: response.body)
            }
            let decoded = try JSONDecoder().decode(SummarizeResponse.self, from: response.body)
            guard !decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SummarizerError.invalidResponse
            }
            guard generation == lifecycleGeneration else { throw CancellationError() }
            await Self.coordinator.finish(permit, error: nil)
            return decoded.summary
        } catch {
            await Self.coordinator.finish(permit, error: error)
            throw error
        }
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
        guard let title = try? await summarize(content: truncatedContent, style: .titleSummary),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    static func parseError(statusCode: Int, body: Data) -> SummarizerError {
        if let envelope = try? JSONDecoder().decode(SummarizerErrorEnvelope.self, from: body) {
            return .requestFailed(statusCode: statusCode, code: envelope.code)
        }
        return .requestFailed(statusCode: statusCode, code: nil)
    }

    static func isTransient(_ error: Error) -> Bool {
        if case SummarizerError.requestFailed(let statusCode, _) = error {
            return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
        }
        return URLErrorClassifier.isConnectivityFailure(error)
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

private struct SummarizerErrorEnvelope: Decodable {
    let code: String?
    let error: String?
    let message: String?
}

enum SummarizerError: LocalizedError, Equatable {
    case requestFailed(statusCode: Int, code: String?)
    case invalidResponse
    case temporarilyUnavailable
    case busy

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, _):
            return "Summarize request failed with status: \(statusCode)"
        case .invalidResponse:
            return "The summarizer returned an invalid response"
        case .temporarilyUnavailable:
            return "The summarizer is temporarily unavailable"
        case .busy:
            return "The summarizer is busy"
        }
    }
}
