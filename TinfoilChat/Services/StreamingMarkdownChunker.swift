//
//  StreamingMarkdownChunker.swift
//  TinfoilChat
//
//  Created on 18/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import Foundation

enum ContentChunkType: Codable, Equatable, Hashable {
    case paragraph
    case codeBlock(language: String?)
    case heading
    case list
    case blockquote
    case table
    case other
}

struct ContentChunk: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let type: ContentChunkType
    let content: String
    let isComplete: Bool

    init(id: String = UUID().uuidString, type: ContentChunkType, content: String, isComplete: Bool) {
        self.id = id
        self.type = type
        self.content = content
        self.isComplete = isComplete
    }
}

class StreamingMarkdownChunker {
    private var completedChunks: [ContentChunk] = []
    private var workingBuffer: String = ""
    private var isInCodeBlock = false
    private var isInTable = false
    private var codeBlockLanguage: String?
    private var codeBlockFenceCount = 0
    private var isFinalized: Bool = false

    func getAllChunks() -> [ContentChunk] {
        var result = completedChunks

        if !workingBuffer.isEmpty {
            let chunkType: ContentChunkType = isInTable ? .table : (isInCodeBlock ? .codeBlock(language: codeBlockLanguage) : .paragraph)
            let chunkId = isInTable ? "working_table" : "working_current"
            result.append(ContentChunk(
                id: chunkId,
                type: chunkType,
                content: workingBuffer,
                isComplete: false
            ))
        }

        return result
    }

    @discardableResult
    func appendToken(_ token: String) -> Bool {
        workingBuffer += token
        var didFinalizeChunk = false

        while true {
            if isInCodeBlock {
                if let trailingContent = extractTrailingContentAfterCodeBlock() {
                    finalizeCodeBlock(preserveAfterFence: trailingContent)
                    didFinalizeChunk = true
                    continue
                }
                return didFinalizeChunk
            }

            if isInTable {
                if let (tableContent, trailingContent) = splitCompletedTableBuffer() {
                    finalizeTable(tableContent: tableContent, preserveTrailingContent: trailingContent)
                    didFinalizeChunk = true
                    continue
                }
                return didFinalizeChunk
            }

            if detectCodeBlockStart() {
                didFinalizeChunk = true
                continue
            }

            if detectTableStart() {
                didFinalizeChunk = true
                continue
            }

            if finalizeParagraphIfNeeded() {
                didFinalizeChunk = true
                continue
            }

            return didFinalizeChunk
        }
    }

    private func finalizeCodeBlock(preserveAfterFence: String = "") {
        let chunkId = "codeblock_\(workingBuffer.hashValue)_\(Date().timeIntervalSince1970)"
        completedChunks.append(ContentChunk(
            id: chunkId,
            type: .codeBlock(language: codeBlockLanguage),
            content: workingBuffer,
            isComplete: true
        ))

        isInCodeBlock = false
        codeBlockLanguage = nil
        workingBuffer = preserveAfterFence
    }

    private func finalizeTable(tableContent: String? = nil, preserveTrailingContent: String = "") {
        let trimmed = (tableContent ?? workingBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let chunkId = "table_\(trimmed.hashValue)_\(Date().timeIntervalSince1970)"
            completedChunks.append(ContentChunk(
                id: chunkId,
                type: .table,
                content: trimmed,
                isComplete: true
            ))
        }

        isInTable = false
        workingBuffer = preserveTrailingContent
    }

    func finalize() {
        isFinalized = true

        if isInCodeBlock {
            finalizeCodeBlock()
        } else if isInTable {
            if let (tableContent, trailingContent) = splitCompletedTableBuffer(allowIncompleteTrailingContent: true) {
                finalizeTable(tableContent: tableContent, preserveTrailingContent: trailingContent)
                if !workingBuffer.isEmpty {
                    finalize()
                }
            } else {
                finalizeTable()
            }
        } else if !workingBuffer.isEmpty {
            let trimmed = workingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let chunkId = "paragraph_\(trimmed.hashValue)_\(Date().timeIntervalSince1970)"
                completedChunks.append(ContentChunk(
                    id: chunkId,
                    type: .paragraph,
                    content: trimmed,
                    isComplete: true
                ))
                workingBuffer = ""
            }
        }
    }

    func reset() {
        completedChunks.removeAll()
        workingBuffer = ""
        isInCodeBlock = false
        isInTable = false
        codeBlockLanguage = nil
        isFinalized = false
    }

    private func detectCodeBlockStart() -> Bool {
        guard let fenceRange = workingBuffer.range(of: "```") else { return false }

        let beforeFence = String(workingBuffer[..<fenceRange.lowerBound])
        appendCompletedParagraph(beforeFence)

        let afterFence = String(workingBuffer[fenceRange.upperBound...])
        let langLine = afterFence.components(separatedBy: .newlines).first ?? ""
        codeBlockLanguage = langLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if codeBlockLanguage?.isEmpty == true {
            codeBlockLanguage = nil
        }

        isInCodeBlock = true
        workingBuffer = String(workingBuffer[fenceRange.lowerBound...])
        return true
    }

    private func extractTrailingContentAfterCodeBlock() -> String? {
        guard workingBuffer.hasSuffix("```") || workingBuffer.contains("\n```\n") || workingBuffer.contains("\n```") else {
            return nil
        }
        guard let closingRange = workingBuffer.range(of: "```", options: .backwards) else {
            return nil
        }
        guard closingRange.lowerBound != workingBuffer.startIndex else {
            return nil
        }

        let afterFence = String(workingBuffer[closingRange.upperBound...])
        if afterFence.trimmingCharacters(in: .whitespaces).isEmpty || afterFence.hasPrefix("\n") {
            return afterFence
        }

        return nil
    }

    private func detectTableStart() -> Bool {
        let lines = workingBuffer.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return false }

        let headerLine = lines[lines.count - 2]
        let alignmentLine = lines[lines.count - 1]
        let trimmedHeader = headerLine.trimmingCharacters(in: .whitespaces)

        guard trimmedHeader.contains("|"),
              isAlignmentLine(alignmentLine) else {
            return false
        }

        let tablePrefix = "\(headerLine)\n\(alignmentLine)"
        guard let tableStartRange = workingBuffer.range(of: tablePrefix, options: .backwards) else {
            return false
        }

        let beforeTable = String(workingBuffer[..<tableStartRange.lowerBound])
        appendCompletedParagraph(beforeTable)

        workingBuffer = String(workingBuffer[tableStartRange.lowerBound...])
        isInTable = true
        return true
    }

    private func splitCompletedTableBuffer(allowIncompleteTrailingContent: Bool = false) -> (table: String, trailing: String)? {
        let lines = bufferedLines()
        guard lines.count >= 2 else { return nil }

        for (index, line) in lines.enumerated() where index >= 2 {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let isIncompleteCurrentLine = index == lines.count - 1 && !line.hasTerminatingNewline

            if trimmed.isEmpty {
                guard !isIncompleteCurrentLine else { return nil }
                let tableEnd = line.range.lowerBound
                return (
                    table: String(workingBuffer[..<tableEnd]),
                    trailing: String(workingBuffer[tableEnd...])
                )
            }

            guard isPotentialTableRow(line.text) else {
                guard !isIncompleteCurrentLine || allowIncompleteTrailingContent else { return nil }
                let tableEnd = line.range.lowerBound
                return (
                    table: String(workingBuffer[..<tableEnd]),
                    trailing: String(workingBuffer[tableEnd...])
                )
            }
        }

        return nil
    }

    private func finalizeParagraphIfNeeded() -> Bool {
        guard workingBuffer.hasSuffix("\n\n"), workingBuffer.count > 2 else {
            return false
        }

        let content = String(workingBuffer.dropLast(2))
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendCompletedParagraph(content)
            workingBuffer = "\n\n"
            return true
        }

        return false
    }

    private func appendCompletedParagraph(_ content: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let chunkId = "paragraph_\(content.hashValue)_\(Date().timeIntervalSince1970)"
        completedChunks.append(ContentChunk(
            id: chunkId,
            type: .paragraph,
            content: content,
            isComplete: true
        ))
    }

    private func isAlignmentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }

        let cells = parseTableCells(from: line)
        guard !cells.isEmpty else { return false }

        let allowedCharacters = CharacterSet(charactersIn: "-: ")
        return cells.allSatisfy { cell in
            let cellTrimmed = cell.trimmingCharacters(in: .whitespaces)
            guard cellTrimmed.contains("-") else { return false }
            return cellTrimmed.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        }
    }

    private func isPotentialTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|")
    }

    private func parseTableCells(from line: String) -> [String] {
        let placeholder = "__ESCAPED_PIPE__"
        var working = line.trimmingCharacters(in: .whitespaces)

        working = working.replacingOccurrences(of: "\\|", with: placeholder)

        while working.hasPrefix("|") {
            working.removeFirst()
        }
        while working.hasSuffix("|") {
            working.removeLast()
        }

        let parts = working.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return parts.map { part in
            part.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    private func bufferedLines() -> [BufferedLine] {
        var lines: [BufferedLine] = []
        var lineStart = workingBuffer.startIndex
        var index = workingBuffer.startIndex

        while index < workingBuffer.endIndex {
            if workingBuffer[index] == "\n" {
                lines.append(BufferedLine(
                    text: String(workingBuffer[lineStart..<index]),
                    range: lineStart..<index,
                    hasTerminatingNewline: true
                ))
                lineStart = workingBuffer.index(after: index)
            }
            index = workingBuffer.index(after: index)
        }

        lines.append(BufferedLine(
            text: String(workingBuffer[lineStart..<workingBuffer.endIndex]),
            range: lineStart..<workingBuffer.endIndex,
            hasTerminatingNewline: false
        ))

        return lines
    }

    private struct BufferedLine {
        let text: String
        let range: Range<String.Index>
        let hasTerminatingNewline: Bool
    }
}
