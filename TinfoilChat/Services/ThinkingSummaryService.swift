//
//  ThinkingSummaryService.swift
//  TinfoilChat
//
//  Service for generating brief summaries of thinking content using the summarizer enclave
//

import Foundation

/// Service for generating thinking summaries during streaming
@MainActor
class ThinkingSummaryService {
    typealias Summarize = @Sendable (String) async throws -> String

    private var isGenerating = false
    private var currentSummary: String = ""
    private var generationTask: Task<Void, Never>?
    private var lastGenerationTime: Date?
    private var summarizedContentLength: Int = 0
    private var pendingThoughts: String?
    private var generationID = 0
    private let summarize: Summarize
    private let cooldownSeconds: TimeInterval

    init(
        cooldownSeconds: TimeInterval = Constants.ThinkingSummary.cooldownSeconds,
        summarize: @escaping Summarize = { content in
            try await SummarizerService.shared.summarize(
                content: content,
                style: .thoughtsSummary
            )
        }
    ) {
        self.cooldownSeconds = cooldownSeconds
        self.summarize = summarize
    }

    /// Generate a summary of the thinking content
    /// - Parameters:
    ///   - thoughts: The current thinking text to summarize
    ///   - completion: Called with the generated summary on the main actor
    func generateSummary(thoughts: String, completion: @escaping @MainActor (String) -> Void) {
        guard thoughts.count - summarizedContentLength >= Constants.ThinkingSummary.minContentLength else {
            return
        }
        pendingThoughts = thoughts
        startLatestIfPossible(completion: completion)
    }

    private func startLatestIfPossible(completion: @escaping @MainActor (String) -> Void) {
        guard !isGenerating, let thoughts = pendingThoughts else { return }
        if let lastGenerationTime {
            let remaining = cooldownSeconds
                - Date().timeIntervalSince(lastGenerationTime)
            if remaining > 0 {
                generationTask?.cancel()
                let scheduledID = generationID
                generationTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    guard !Task.isCancelled,
                          let self,
                          self.generationID == scheduledID else { return }
                    self.generationTask = nil
                    self.startLatestIfPossible(completion: completion)
                }
                return
            }
        }

        pendingThoughts = nil
        let words = thoughts.split(separator: " ")
        let tailText = words.count > Constants.ThinkingSummary.tailWordCount
            ? words.suffix(Constants.ThinkingSummary.tailWordCount).joined(separator: " ")
            : thoughts
        generationID += 1
        let requestID = generationID
        let contentLengthAtGeneration = thoughts.count
        isGenerating = true
        lastGenerationTime = Date()

        generationTask = Task { [weak self] in
            guard let self else { return }
            var successfulSummary: String?
            do {
                let summary = try await self.summarize(tailText)
                if !Task.isCancelled, !summary.isEmpty {
                    successfulSummary = summary
                }
            } catch {
            }

            guard self.generationID == requestID else { return }
            self.isGenerating = false
            self.generationTask = nil
            if let successfulSummary {
                self.currentSummary = successfulSummary
                self.summarizedContentLength = contentLengthAtGeneration
                completion(successfulSummary)
            }
            self.startLatestIfPossible(completion: completion)
        }
    }

    /// Reset state for a new thinking session
    func reset() {
        generationID += 1
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        currentSummary = ""
        lastGenerationTime = nil
        summarizedContentLength = 0
        pendingThoughts = nil
    }

    /// Get the current summary without generating a new one
    var summary: String {
        currentSummary
    }
}
