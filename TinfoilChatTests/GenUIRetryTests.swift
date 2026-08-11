//
//  GenUIRetryTests.swift
//  TinfoilChatTests
//

import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

struct GenUIRetryTests {
    private enum RequestError: Error {
        case authentication
    }

    private final class RequestRecorder {
        var requestCount = 0
        var recoveryCount = 0
    }

    @Test func repairPromptIncludesTheCompleteFailedArguments() throws {
        let failedArguments = #"{"source":{"type":"html","html":"<main>complete payload</main>"}}"#

        let prompt = GenUIRetryPrompt.user(
            widgetName: "render_artifact_preview",
            failedArguments: failedArguments
        )

        #expect(prompt.hasSuffix(failedArguments))
    }

    @Test func retryHistoryRemovesToolPayloadsWithoutTruncatingMessageContent() throws {
        let failedArguments = #"{"source":{"type":"html","html":"<main>complete payload</main>"}}"#
        let fullContent = "Keep this complete assistant explanation, including its ending."
        var assistant = Message(role: .assistant, content: fullContent)
        assistant.toolCalls = [
            GenUIToolCall(
                id: "call-1",
                name: "render_artifact_preview",
                arguments: failedArguments
            ),
        ]
        assistant.timeline = [
            .object([
                "type": .string("content"),
                "content": .string(fullContent),
            ]),
            .object([
                "type": .string("tool_call"),
                "toolCallId": .string("call-1"),
                "name": .string("render_artifact_preview"),
                "arguments": .string(failedArguments),
            ]),
        ]

        let history = GenUIRetryContext.sanitizedHistory([assistant])
        let sanitized = try #require(history.first)
        let repairMessage = GenUIRetryPrompt.user(
            widgetName: "render_artifact_preview",
            failedArguments: failedArguments
        )
        let requestText = history.map(\.content).joined() + repairMessage

        #expect(sanitized.content == fullContent)
        #expect(sanitized.toolCalls.isEmpty)
        #expect(sanitized.timeline?.count == 1)
        #expect(sanitized.timeline?.first?.objectValue?["type"]?.stringValue == "content")
        #expect(requestText.components(separatedBy: failedArguments).count == 2)
    }

    @Test func classifiesStructuredCompletionOutcomes() throws {
        #expect(GenUIRetryResultClassifier.classify(
            finishReason: "stop",
            refusal: nil,
            content: "{}"
        ) == .output("{}"))
        #expect(GenUIRetryResultClassifier.classify(
            finishReason: "length",
            refusal: nil,
            content: "{"
        ) == .invalidOutput(.incompleteResponse))
        #expect(GenUIRetryResultClassifier.classify(
            finishReason: "content_filter",
            refusal: nil,
            content: nil
        ) == .invalidOutput(.incompleteResponse))
        #expect(GenUIRetryResultClassifier.classify(
            finishReason: "other",
            refusal: nil,
            content: "{}"
        ) == .invalidOutput(.incompleteResponse))
        #expect(GenUIRetryResultClassifier.classify(
            finishReason: "stop",
            refusal: "Unable to comply",
            content: nil
        ) == .invalidOutput(.refusal))
    }

    @Test func streamingPlaceholderOnlyCoversIncompleteJSON() throws {
        #expect(GenUIToolCallPresentation.showsPlaceholder(
            arguments: #"{"source":"#,
            isRenderingStream: true
        ))
        #expect(!GenUIToolCallPresentation.showsPlaceholder(
            arguments: #"{"source":{"type":"markdown","markdown":"Complete"}}"#,
            isRenderingStream: true
        ))
        #expect(!GenUIToolCallPresentation.showsPlaceholder(
            arguments: "{}",
            isRenderingStream: true
        ))
        #expect(!GenUIToolCallPresentation.showsPlaceholder(
            arguments: #"{"source":"#,
            isRenderingStream: false
        ))
    }

    @MainActor
    @Test func distinguishesInvalidJSONObjectFromWidgetShapeMismatch() throws {
        let widget = ArtifactPreviewWidget()

        let invalidObject = GenUIArgumentValidator.validationError(
            rawArgs: Data("[]".utf8),
            widget: widget
        )
        let shapeMismatch = GenUIArgumentValidator.validationError(
            rawArgs: Data("{}".utf8),
            widget: widget
        )

        #expect(invalidObject == .invalidJSONObject)
        #expect(shapeMismatch == .widgetDecoding(codingPath: "$.source"))
    }

    @MainActor
    @Test func acceptsArgumentsThatTheRegisteredWidgetCanDecode() throws {
        let widget = ArtifactPreviewWidget()
        let arguments = ##"{"source":{"type":"markdown","markdown":"# Artifact"}}"##

        #expect(GenUIArgumentValidator.validationError(
            rawArgs: Data(arguments.utf8),
            widget: widget
        ) == nil)
    }

    @MainActor
    @Test func artifactSourceRequiresThePayloadMatchingItsDiscriminator() throws {
        let widget = ArtifactPreviewWidget()
        let mismatches: [(arguments: String, path: String)] = [
            (#"{"source":{"type":"url","html":"content"}}"#, "$.source.url"),
            (#"{"source":{"type":"html","markdown":"content"}}"#, "$.source.html"),
            (#"{"source":{"type":"markdown","url":"https://example.com"}}"#, "$.source.markdown"),
        ]

        for mismatch in mismatches {
            #expect(GenUIArgumentValidator.validationError(
                rawArgs: Data(mismatch.arguments.utf8),
                widget: widget
            ) == .widgetDecoding(codingPath: mismatch.path))
        }

        let emptyPayloads = [
            #"{"source":{"type":"url","url":""}}"#,
            #"{"source":{"type":"html","html":""}}"#,
            #"{"source":{"type":"markdown","markdown":""}}"#,
        ]
        for arguments in emptyPayloads {
            #expect(GenUIArgumentValidator.validationError(
                rawArgs: Data(arguments.utf8),
                widget: widget
            ) == nil)
        }
    }

    @MainActor
    @Test func authenticationRecoveryRetriesTheSameOperationOnce() async throws {
        let recorder = RequestRecorder()

        let result = try await GenUIRetryRequestExecutor.execute(
            request: {
                recorder.requestCount += 1
                if recorder.requestCount == 1 {
                    throw RequestError.authentication
                }
                return "structured output"
            },
            recoverAuthentication: {
                recorder.recoveryCount += 1
            },
            isAuthenticationError: { $0 is RequestError }
        )

        #expect(result == "structured output")
        #expect(recorder.requestCount == 2)
        #expect(recorder.recoveryCount == 1)
    }

    @MainActor
    @Test func authenticationRecoveryDoesNotRetryMoreThanOnce() async {
        let recorder = RequestRecorder()

        await #expect(throws: RequestError.self) {
            let _: String = try await GenUIRetryRequestExecutor.execute(
                request: {
                    recorder.requestCount += 1
                    throw RequestError.authentication
                },
                recoverAuthentication: {
                    recorder.recoveryCount += 1
                },
                isAuthenticationError: { $0 is RequestError }
            )
        }

        #expect(recorder.requestCount == 2)
        #expect(recorder.recoveryCount == 1)
    }

    @Test func patchesOnlyTheMatchingToolCallAndTimelineBlock() throws {
        let failedArguments = #"{"source":{"type":"markdown"}}"#
        let regeneratedArguments = #"{"source":{"type":"markdown","markdown":"Complete"}}"#
        var message = Message(role: .assistant, content: "Unchanged prose")
        message.toolCalls = [
            GenUIToolCall(id: "call-1", name: "render_artifact_preview", arguments: failedArguments),
            GenUIToolCall(id: "call-2", name: "render_clock", arguments: #"{"timezone":"UTC"}"#),
        ]
        message.timeline = [
            .object([
                "type": .string("tool_call"),
                "toolCallId": .string("call-1"),
                "name": .string("render_artifact_preview"),
                "arguments": .string(failedArguments),
            ]),
        ]

        let patched = TimelineToolCalls.replaceArguments(
            in: &message,
            toolCallId: "call-1",
            name: "render_artifact_preview",
            expectedArguments: failedArguments,
            newArguments: regeneratedArguments
        )

        #expect(patched)
        #expect(message.content == "Unchanged prose")
        #expect(message.toolCalls[0].arguments == regeneratedArguments)
        #expect(message.toolCalls[1].arguments == #"{"timezone":"UTC"}"#)
        #expect(message.timeline?[0].objectValue?["arguments"]?.stringValue == regeneratedArguments)
    }

    @Test func rejectsAStaleTimelineWithoutChangingTheMessage() throws {
        let failedArguments = #"{"source":{"type":"markdown"}}"#
        var message = Message(role: .assistant, content: "Unchanged prose")
        message.toolCalls = [
            GenUIToolCall(id: "call-1", name: "render_artifact_preview", arguments: failedArguments),
        ]
        message.timeline = [
            .object([
                "type": .string("tool_call"),
                "toolCallId": .string("call-1"),
                "name": .string("render_artifact_preview"),
                "arguments": .string("newer arguments"),
            ]),
        ]

        let original = message
        let patched = TimelineToolCalls.replaceArguments(
            in: &message,
            toolCallId: "call-1",
            name: "render_artifact_preview",
            expectedArguments: failedArguments,
            newArguments: #"{"source":{"type":"markdown","markdown":"Complete"}}"#
        )

        #expect(!patched)
        #expect(message == original)
    }

    @MainActor
    @Test func queryBuilderCarriesStructuredResponseFormatWithoutTools() throws {
        let responseFormat = ChatQuery.ResponseFormat.jsonSchema(.init(
            name: "regenerated_widget_arguments",
            schema: .jsonSchema(ArtifactPreviewWidget().schema),
            strict: false
        ))

        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "Repair the widget.",
            rules: "",
            conversationMessages: [Message(role: .user, content: "Full failed arguments")],
            stream: false,
            genUIEnabled: false,
            responseFormat: responseFormat
        )

        #expect(query.responseFormat == responseFormat)
        #expect(query.tools == nil)
        #expect(query.stream == false)
    }
}
