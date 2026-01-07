//
//  ThinkingSummaryService.swift
//  TinfoilChat
//
//  Service for generating brief summaries of thinking content using the title model
//

import Foundation
import OpenAI
import TinfoilAI

/// Service for generating thinking summaries during streaming
@MainActor
class ThinkingSummaryService {
    static let shared = ThinkingSummaryService()

    private var isGenerating = false
    private var currentSummary: String = ""
    private var generationTask: Task<Void, Never>?

    private init() {}

    /// Generate a summary of the thinking content
    /// - Parameters:
    ///   - thoughts: The current thinking text to summarize
    ///   - client: The TinfoilAI client to use for generation (reuse existing client)
    ///   - completion: Called with the generated summary on the main actor
    func generateSummary(thoughts: String, client: TinfoilAI, completion: @escaping @MainActor (String) -> Void) {
        guard let titleModel = AppConfig.shared.titleModel else {
            return
        }

        // Only generate if we have enough content
        guard thoughts.count >= Constants.ThinkingSummary.minContentLength else {
            return
        }

        // Don't start a new generation if one is already in progress
        guard !isGenerating else {
            return
        }

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
                )

                let result = try await client.chats(query: query)

                if let summary = result.choices.first?.message.content,
                   !summary.isEmpty {
                    let cleanSummary = Self.cleanupSummary(summary)
                    if !cleanSummary.isEmpty {
                        self.currentSummary = cleanSummary
                        completion(cleanSummary)
                    }
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
    }

    /// Get the current summary without generating a new one
    var summary: String {
        currentSummary
    }

    /// Clean up the generated summary: remove quotes, dots, possessives, and capitalize
    private static func cleanupSummary(_ summary: String) -> String {
        let cleaned = summary
            .replacingOccurrences(of: "[\".]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b(my|your|yours|mine|our|ours|their|theirs|his|her|hers)\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}
