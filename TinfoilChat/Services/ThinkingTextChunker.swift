//
//  ThinkingTextChunker.swift
//  TinfoilChat
//
//  Splits streaming thinking/reasoning text into paragraph chunks
//  so that only the active (last) chunk needs re-rendering during streaming.
//

import Foundation

struct ThinkingChunk: Identifiable, Equatable, Hashable {
    let id: String
    let content: String
    let isComplete: Bool
}

class ThinkingTextChunker {
    private var completedChunks: [ThinkingChunk] = []
    private var workingBuffer: String = ""

    func getAllChunks() -> [ThinkingChunk] {
        var result = completedChunks

        if !workingBuffer.isEmpty {
            result.append(ThinkingChunk(
                id: "thinking_working_\(completedChunks.count)",
                content: workingBuffer,
                isComplete: false
            ))
        }

        return result
    }

    func appendToken(_ token: String) {
        workingBuffer += token

        // Split on double-newline paragraph boundaries
        while let range = workingBuffer.range(of: "\n\n") {
            let paragraph = String(workingBuffer[..<range.lowerBound])
            if !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let chunkId = "thinking_\(completedChunks.count)"
                completedChunks.append(ThinkingChunk(
                    id: chunkId,
                    content: paragraph,
                    isComplete: true
                ))
            }
            workingBuffer = String(workingBuffer[range.upperBound...])
        }
    }

    /// Appends a late fragment of an already-finalized thought to the last
    /// completed chunk so it continues that paragraph instead of starting a
    /// new one.
    func appendTail(_ token: String) {
        if workingBuffer.isEmpty, !completedChunks.isEmpty {
            let last = completedChunks[completedChunks.count - 1]
            completedChunks[completedChunks.count - 1] = ThinkingChunk(
                id: last.id,
                content: last.content + token,
                isComplete: true
            )
        } else {
            appendToken(token)
        }
    }

    func finalize() {
        if !workingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let chunkId = "thinking_\(completedChunks.count)"
            completedChunks.append(ThinkingChunk(
                id: chunkId,
                content: workingBuffer,
                isComplete: true
            ))
        }
        workingBuffer = ""
    }

    func reset() {
        completedChunks.removeAll()
        workingBuffer = ""
    }
}
