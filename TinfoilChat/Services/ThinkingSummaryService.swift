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
    static let shared = ThinkingSummaryService()

    private var isGenerating = false
    private var currentSummary: String = ""
    private var generationTask: Task<Void, Never>?
    private var lastGenerationTime: Date?
    private var summarizedContentLength: Int = 0

    private init() {}

    /// Generate a summary of the thinking content
    /// - Parameters:
    ///   - thoughts: The current thinking text to summarize
    ///   - completion: Called with the generated summary on the main actor
    func generateSummary(thoughts: String, completion: @escaping @MainActor (String) -> Void) {
        let newContent = String(thoughts.dropFirst(summarizedContentLength))

        // Only generate if we have enough new content
        guard newContent.count >= Constants.ThinkingSummary.minContentLength else {
            return
        }

        // Send only the tail of the thoughts so the summary reflects current reasoning
        let words = thoughts.split(separator: " ")
        let tailText: String
        if words.count > Constants.ThinkingSummary.tailWordCount {
            tailText = words.suffix(Constants.ThinkingSummary.tailWordCount).joined(separator: " ")
        } else {
            tailText = thoughts
        }

        // Don't start a new generation if one is already in progress
        guard !isGenerating else {
            return
        }

        // Enforce cooldown between generations
        if let lastTime = lastGenerationTime,
           Date().timeIntervalSince(lastTime) < Constants.ThinkingSummary.cooldownSeconds {
            return
        }

        isGenerating = true
        lastGenerationTime = Date()
        let contentLengthAtGeneration = thoughts.count

        // Cancel any pending generation
        generationTask?.cancel()

        generationTask = Task { [weak self] in
            guard let self = self else { return }

            defer {
                Task { @MainActor in
                    self.isGenerating = false
                    self.summarizedContentLength = contentLengthAtGeneration
                }
            }

            do {
                let summary = try await SummarizerService.shared.summarize(
                    content: tailText,
                    style: .thoughtsSummary
                )

                guard !Task.isCancelled else { return }

                if !summary.isEmpty {
                    self.currentSummary = summary
                    completion(summary)
                }
            } catch {
                // Silently fail - summary is optional enhancement
            }
        }
    }

    /// Reset state for a new thinking session
    func reset() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        currentSummary = ""
        lastGenerationTime = nil
        summarizedContentLength = 0
    }

    /// Get the current summary without generating a new one
    var summary: String {
        currentSummary
    }

}
