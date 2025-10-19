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
    private var fullContent: String = ""

    func getAllChunks() -> [ContentChunk] {
        guard !fullContent.isEmpty else { return [] }
        return [ContentChunk(
            type: .paragraph,
            content: fullContent,
            isComplete: false
        )]
    }

    func appendToken(_ token: String) -> Bool {
        fullContent += token
        return false
    }

    func finalize() {
    }

    func reset() {
        fullContent = ""
    }
}
