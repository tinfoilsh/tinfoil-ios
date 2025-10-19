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
    private var completedChunks: [ContentChunk] = []
    private var currentChunk: ContentChunk? = nil

    private var currentChunkType: ContentChunkType = .paragraph
    private var currentChunkContent: String = ""
    private var currentChunkId: String = UUID().uuidString

    private var inCodeBlock: Bool = false
    private var codeBlockLanguage: String? = nil
    private var codeBlockFenceCount: Int = 0

    private var inTable: Bool = false
    private var tableContent: String = ""

    func getAllChunks() -> [ContentChunk] {
        var result = completedChunks
        if let current = currentChunk {
            result.append(current)
        }
        return result
    }

    func appendToken(_ token: String) -> Bool {
        buffer += token
        let hasNewCompletedChunks = processBuffer()

        if !currentChunkContent.isEmpty {
            currentChunk = ContentChunk(
                id: currentChunkId,
                type: currentChunkType,
                content: currentChunkContent,
                isComplete: false
            )
        } else {
            currentChunk = nil
        }

        return hasNewCompletedChunks
    }

    func finalize() {
        if !currentChunkContent.isEmpty {
            completedChunks.append(ContentChunk(
                id: currentChunkId,
                type: currentChunkType,
                content: currentChunkContent,
                isComplete: true
            ))
            currentChunk = nil
            currentChunkContent = ""
        }

        if !buffer.isEmpty {
            completedChunks.append(ContentChunk(
                type: .paragraph,
                content: buffer,
                isComplete: true
            ))
            buffer = ""
        }
    }

    func reset() {
        buffer = ""
        completedChunks = []
        currentChunk = nil
        currentChunkType = .paragraph
        currentChunkContent = ""
        currentChunkId = UUID().uuidString
        inCodeBlock = false
        codeBlockLanguage = nil
        codeBlockFenceCount = 0
        inTable = false
        tableContent = ""
    }

    private func processBuffer() -> Bool {
        var hasNewCompletedChunks = false

        while !buffer.isEmpty {
            if inCodeBlock {
                if let closingRange = buffer.range(of: "```") {
                    let beforeClosing = String(buffer[..<closingRange.lowerBound])
                    currentChunkContent += beforeClosing + "```"

                    completedChunks.append(ContentChunk(
                        id: currentChunkId,
                        type: currentChunkType,
                        content: currentChunkContent,
                        isComplete: true
                    ))
                    hasNewCompletedChunks = true

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
                    break
                }
            } else if inTable {
                if let doubleNewlineRange = buffer.range(of: "\n\n") {
                    let tableRows = String(buffer[..<doubleNewlineRange.lowerBound])
                    currentChunkContent += tableRows

                    completedChunks.append(ContentChunk(
                        id: currentChunkId,
                        type: currentChunkType,
                        content: currentChunkContent,
                        isComplete: true
                    ))
                    hasNewCompletedChunks = true

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
                        completedChunks.append(ContentChunk(
                            id: currentChunkId,
                            type: currentChunkType,
                            content: currentChunkContent,
                            isComplete: true
                        ))
                        hasNewCompletedChunks = true

                        inTable = false
                        tableContent = ""

                        currentChunkType = .paragraph
                        currentChunkContent = lastLine + "\n"
                        currentChunkId = UUID().uuidString
                    }
                } else {
                    break
                }
            } else {
                if buffer.hasPrefix("```") {
                    if !currentChunkContent.isEmpty {
                        completedChunks.append(ContentChunk(
                            id: currentChunkId,
                            type: currentChunkType,
                            content: currentChunkContent,
                            isComplete: true
                        ))
                        hasNewCompletedChunks = true
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
                        completedChunks.append(ContentChunk(
                            id: currentChunkId,
                            type: currentChunkType,
                            content: currentChunkContent,
                            isComplete: true
                        ))
                        hasNewCompletedChunks = true
                    }

                    currentChunkType = .table
                    currentChunkContent = ""
                    currentChunkId = UUID().uuidString
                    inTable = true
                    tableContent = ""
                } else if let doubleNewlineRange = buffer.range(of: "\n\n") {
                    let paragraph = String(buffer[..<doubleNewlineRange.lowerBound])
                    currentChunkContent += paragraph

                    completedChunks.append(ContentChunk(
                        id: currentChunkId,
                        type: currentChunkType,
                        content: currentChunkContent,
                        isComplete: true
                    ))
                    hasNewCompletedChunks = true

                    buffer = String(buffer[doubleNewlineRange.upperBound...])

                    currentChunkType = .paragraph
                    currentChunkContent = ""
                    currentChunkId = UUID().uuidString
                } else {
                    currentChunkContent += buffer
                    buffer = ""
                    break
                }
            }
        }

        return hasNewCompletedChunks
    }
}
