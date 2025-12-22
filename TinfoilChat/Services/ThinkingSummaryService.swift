//
//  ThinkingSummaryService.swift
//  TinfoilChat
//
//  Service for generating brief summaries of thinking content using the title model
//

import Foundation
import OpenAI

/// Service for generating thinking summaries during streaming
@MainActor
class ThinkingSummaryService {
    static let shared = ThinkingSummaryService()

    private var isGenerating = false
    private var lastThoughtsLength = 0
    private var currentSummary: String = ""
    private var generationTask: Task<Void, Never>?

    private init() {}

    /// Generate a summary of the thinking content
    /// - Parameters:
    ///   - thoughts: The current thinking text to summarize
    ///   - client: The OpenAI client to use for generation (reuse existing client)
    ///   - completion: Called with the generated summary on the main actor
    func generateSummary(thoughts: String, client: OpenAI, completion: @escaping @MainActor (String) -> Void) {
        guard let titleModel = AppConfig.shared.titleModel else {
            return
        }

        let thoughtsLength = thoughts.count

        // Only generate if we have enough content
        guard thoughtsLength >= Constants.ThinkingSummary.minContentLength else {
            return
        }

        // Only generate if we have enough new content since last generation
        let newContentLength = thoughtsLength - lastThoughtsLength
        guard newContentLength >= Constants.ThinkingSummary.minNewContentLength || lastThoughtsLength == 0 else {
            return
        }

        // Don't start a new generation if one is already in progress
        guard !isGenerating else {
            return
        }

        lastThoughtsLength = thoughtsLength
        isGenerating = true

        // Cancel any pending generation
        generationTask?.cancel()

        let modelName = titleModel.modelName

        generationTask = Task { [weak self] in
            guard let self = self else { return }

            defer {
                Task { @MainActor in
                    self.isGenerating = false
                }
            }

            do {
                let query = ChatQuery(
                    messages: [
                        .system(.init(content: .textContent(Constants.ThinkingSummary.systemPrompt))),
                        .user(.init(content: .string(thoughts)))
                    ],
                    model: modelName,
                    maxCompletionTokens: Constants.ThinkingSummary.maxTokens
                )

                let result = try await client.chats(query: query)

                if let summary = result.choices.first?.message.content,
                   !summary.isEmpty {
                    let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.currentSummary = trimmedSummary
                    completion(trimmedSummary)
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
        lastThoughtsLength = 0
        currentSummary = ""
    }

    /// Get the current summary without generating a new one
    var summary: String {
        currentSummary
    }
}
