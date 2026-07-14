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
                appendCompletedChunk(paragraph)
            }
            workingBuffer = String(workingBuffer[range.upperBound...])
        }

        // A single paragraph with no blank lines can grow without bound;
        // flush completed pieces so the working chunk stays capped.
        if workingBuffer.count > Constants.Rendering.maxThinkingChunkCharacters {
            var pieces = Self.hardSplit(workingBuffer)
            workingBuffer = pieces.removeLast()
            for piece in pieces {
                appendCompletedChunk(piece)
            }
        }
    }

    /// Appends a late fragment of an already-finalized thought to the last
    /// completed chunk so it continues that paragraph instead of starting a
    /// new one.
    func appendTail(_ token: String) {
        if workingBuffer.isEmpty, !completedChunks.isEmpty {
            let last = completedChunks.removeLast()
            // Re-split the grown chunk so a long late tail can never
            // push it past the per-chunk layout cap. The first piece
            // keeps its id so the existing view identity is stable.
            var pieces = Self.hardSplit(last.content + token)
            let first = pieces.removeFirst()
            completedChunks.append(ThinkingChunk(
                id: last.id,
                content: first,
                isComplete: true
            ))
            for piece in pieces {
                appendCompletedChunk(piece)
            }
        } else {
            appendToken(token)
        }
    }

    func finalize() {
        if !workingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendCompletedChunk(workingBuffer)
        }
        workingBuffer = ""
    }

    func reset() {
        completedChunks.removeAll()
        workingBuffer = ""
    }

    /// One-shot chunking for already-complete thinking text, e.g. thoughts
    /// loaded from storage where the streaming chunks were not persisted.
    static func chunk(_ text: String) -> [ThinkingChunk] {
        let chunker = ThinkingTextChunker()
        chunker.appendToken(text)
        chunker.finalize()
        return chunker.getAllChunks()
    }

    private func appendCompletedChunk(_ content: String) {
        for piece in Self.hardSplit(content) {
            completedChunks.append(ThinkingChunk(
                id: "thinking_\(completedChunks.count)",
                content: piece,
                isComplete: true
            ))
        }
    }

    /// Splits text into pieces no longer than the chunk cap, preferring the
    /// last newline before the cap so lines stay intact.
    private static func hardSplit(_ text: String) -> [String] {
        let cap = Constants.Rendering.maxThinkingChunkCharacters
        guard text.count > cap else { return [text] }

        var pieces: [String] = []
        var remainder = Substring(text)
        // `limitedBy:` keeps each split O(cap) instead of rescanning the
        // whole remaining suffix with `count` on every iteration.
        while let capIndex = remainder.index(
            remainder.startIndex, offsetBy: cap, limitedBy: remainder.endIndex
        ), capIndex != remainder.endIndex {
            let window = remainder[..<capIndex]
            let splitIndex = window.lastIndex(of: "\n").map { remainder.index(after: $0) } ?? capIndex
            pieces.append(String(remainder[..<splitIndex]))
            remainder = remainder[splitIndex...]
        }
        if !remainder.isEmpty {
            pieces.append(String(remainder))
        }
        return pieces
    }
}
