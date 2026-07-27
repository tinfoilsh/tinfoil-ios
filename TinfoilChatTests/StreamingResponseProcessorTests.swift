import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

@Suite("Streaming response completion")
struct StreamingResponseProcessorTests {
    @Test("rejects a response without a finish reason")
    func rejectsIncompleteResponse() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        let parsed = processor.parse(try chunk(content: "partial"))
        _ = processor.process(parsed)

        #expect(throws: StreamingResponseProcessorError.self) {
            try processor.finishStream()
        }
    }

    @Test("accepts authenticated finish reasons", arguments: [
        "stop",
        "length",
        "content_filter",
        "tool_calls",
        "function_call",
    ])
    func acceptsFinishReason(_ finishReason: String) throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        let content = processor.parse(try chunk(content: "complete"))
        _ = processor.process(content)
        let terminal = processor.parse(
            try chunk(content: "", finishReason: finishReason)
        )
        _ = processor.process(terminal)

        try processor.finishStream()

        #expect(processor.snapshot().responseContent == "complete")
    }

    private func chunk(
        content: String,
        finishReason: String? = nil
    ) throws -> ChatStreamResult {
        var choice: [String: Any] = [
            "index": 0,
            "delta": ["content": content],
        ]
        choice["finish_reason"] = finishReason.map { $0 as Any } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl-test",
            "object": "chat.completion.chunk",
            "created": 1,
            "model": "gpt-oss-120b",
            "choices": [choice],
        ])
        return try JSONDecoder().decode(ChatStreamResult.self, from: data)
    }
}
