//
//  StreamingMarkdownChunker.swift
//  TinfoilChat
//
//  Created on 18/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import Foundation

enum ContentChunkType: Codable, Equatable {
    case paragraph
    case codeBlock(language: String?)
    case heading
    case list
    case blockquote
    case table
    case other
}

struct ContentChunk: Codable, Equatable, Identifiable {
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
    private var buffer: String = ""
    private var chunks: [ContentChunk] = []
    private var currentChunkType: ContentChunkType = .paragraph
    private var currentChunkContent: String = ""
    private var currentChunkId: String = UUID().uuidString

    private var inCodeBlock: Bool = false
    private var codeBlockLanguage: String? = nil
    private var codeBlockFenceCount: Int = 0

    private var inTable: Bool = false
    private var tableContent: String = ""

    func appendToken(_ token: String) -> (completed: [ContentChunk], current: ContentChunk?) {
        buffer += token
        let completedChunks = processBuffer()

        let currentChunk: ContentChunk? = if !currentChunkContent.isEmpty {
            ContentChunk(
                id: currentChunkId,
                type: currentChunkType,
                content: currentChunkContent,
                isComplete: false
            )
        } else {
            nil
        }

        return (completed: completedChunks, current: currentChunk)
    }

    func finalize() -> [ContentChunk] {
        if !currentChunkContent.isEmpty {
            finalizeCurrentChunk()
        }

        if !buffer.isEmpty {
            if chunks.isEmpty || chunks.last?.isComplete == true {
                chunks.append(ContentChunk(
                    type: .paragraph,
                    content: buffer,
                    isComplete: true
                ))
            } else if var lastChunk = chunks.last {
                chunks.removeLast()
                lastChunk = ContentChunk(
                    id: lastChunk.id,
                    type: lastChunk.type,
                    content: lastChunk.content + buffer,
                    isComplete: true
                )
                chunks.append(lastChunk)
            }
            buffer = ""
        }

        let result = chunks
        chunks = []
        return result
    }

    func reset() {
        buffer = ""
        chunks = []
        currentChunkType = .paragraph
        currentChunkContent = ""
        currentChunkId = UUID().uuidString
        inCodeBlock = false
        codeBlockLanguage = nil
        codeBlockFenceCount = 0
        inTable = false
        tableContent = ""
    }

    private func processBuffer() -> [ContentChunk] {
        var newChunks: [ContentChunk] = []

        while !buffer.isEmpty {
            if inCodeBlock {
                if let closingRange = buffer.range(of: "```") {
                    let beforeClosing = String(buffer[..<closingRange.lowerBound])
                    currentChunkContent += beforeClosing + "```"

                    finalizeCurrentChunk()
                    newChunks.append(chunks.removeLast())

                    inCodeBlock = false
                    codeBlockLanguage = nil
                    codeBlockFenceCount = 0
                    buffer = String(buffer[closingRange.upperBound...])

                    currentChunkType = .paragraph
                    currentChunkContent = ""
                    currentChunkId = UUID().uuidString
                } else {
                    currentChunkContent += buffer
                    buffer = ""

                    if !chunks.isEmpty && chunks.last?.id == currentChunkId {
                        chunks.removeLast()
                    }
                    chunks.append(ContentChunk(
                        id: currentChunkId,
                        type: currentChunkType,
                        content: currentChunkContent,
                        isComplete: false
                    ))
                    break
                }
            } else if inTable {
                if let doubleNewlineRange = buffer.range(of: "\n\n") {
                    let tableRows = String(buffer[..<doubleNewlineRange.lowerBound])
                    currentChunkContent += tableRows

                    finalizeCurrentChunk()
                    newChunks.append(chunks.removeLast())

                    inTable = false
                    tableContent = ""
                    buffer = String(buffer[doubleNewlineRange.upperBound...])

                    currentChunkType = .paragraph
                    currentChunkContent = ""
                    currentChunkId = UUID().uuidString
                } else if buffer.contains("\n") && buffer.hasSuffix("\n") {
                    let lines = buffer.components(separatedBy: "\n")
                    let completedLines = lines.dropLast()

                    for line in completedLines where line.contains("|") {
                        currentChunkContent += line + "\n"
                    }

                    buffer = lines.last ?? ""

                    if let lastLine = completedLines.last, !lastLine.contains("|") {
                        finalizeCurrentChunk()
                        newChunks.append(chunks.removeLast())

                        inTable = false
                        tableContent = ""

                        currentChunkType = .paragraph
                        currentChunkContent = lastLine + "\n"
                        currentChunkId = UUID().uuidString
                    } else {
                        if !chunks.isEmpty && chunks.last?.id == currentChunkId {
                            chunks.removeLast()
                        }
                        chunks.append(ContentChunk(
                            id: currentChunkId,
                            type: currentChunkType,
                            content: currentChunkContent,
                            isComplete: false
                        ))
                    }
                } else {
                    break
                }
            } else {
                if buffer.hasPrefix("```") {
                    if !currentChunkContent.isEmpty {
                        finalizeCurrentChunk()
                        newChunks.append(chunks.removeLast())
                    }

                    if let newlineRange = buffer.range(of: "\n") {
                        let firstLine = String(buffer[..<newlineRange.lowerBound])
                        let language = String(firstLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)

                        codeBlockLanguage = language.isEmpty ? nil : language
                        currentChunkType = .codeBlock(language: codeBlockLanguage)
                        currentChunkContent = firstLine + "\n"
                        currentChunkId = UUID().uuidString

                        inCodeBlock = true
                        buffer = String(buffer[newlineRange.upperBound...])
                    } else {
                        codeBlockLanguage = nil
                        currentChunkType = .codeBlock(language: nil)
                        currentChunkContent = buffer
                        currentChunkId = UUID().uuidString

                        inCodeBlock = true
                        buffer = ""
                        break
                    }
                } else if buffer.hasPrefix("|") && !inTable {
                    if !currentChunkContent.isEmpty {
                        finalizeCurrentChunk()
                        newChunks.append(chunks.removeLast())
                    }

                    currentChunkType = .table
                    currentChunkContent = ""
                    currentChunkId = UUID().uuidString
                    inTable = true
                    tableContent = ""
                } else if let doubleNewlineRange = buffer.range(of: "\n\n") {
                    let paragraph = String(buffer[..<doubleNewlineRange.lowerBound])
                    currentChunkContent += paragraph

                    finalizeCurrentChunk()
                    newChunks.append(chunks.removeLast())

                    buffer = String(buffer[doubleNewlineRange.upperBound...])

                    currentChunkType = .paragraph
                    currentChunkContent = ""
                    currentChunkId = UUID().uuidString
                } else {
                    currentChunkContent += buffer
                    buffer = ""

                    if !chunks.isEmpty && chunks.last?.id == currentChunkId {
                        chunks.removeLast()
                    }
                    chunks.append(ContentChunk(
                        id: currentChunkId,
                        type: currentChunkType,
                        content: currentChunkContent,
                        isComplete: false
                    ))
                    break
                }
            }
        }

        return newChunks
    }

    private func finalizeCurrentChunk() {
        if !currentChunkContent.isEmpty {
            chunks.append(ContentChunk(
                id: currentChunkId,
                type: currentChunkType,
                content: currentChunkContent,
                isComplete: true
            ))
        }
    }
}
