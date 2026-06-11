//
//  ErrorExplanationTests.swift
//  TinfoilChatTests
//
//  Verifies that raw backend/SDK error text is mapped to friendly
//  explanations, mirroring the webapp's `explainError` behavior.
//

import Foundation
import Testing
@testable import TinfoilChat

struct ErrorExplanationTests {

    @Test @MainActor
    func mapsEHBPMissingHeaderToServiceTrouble() {
        let raw = "Missing header: Ehbp-Response-Nonce"
        let explained = ChatViewModel.explainRawError(raw)
        #expect(explained?.contains("service is having trouble") == true)
    }

    @Test @MainActor
    func mapsPromptLengthErrorToContextExplanation() {
        let raw = """
        pipeline failed at stage "agent": agent error: agent LLM call failed: POST \
        "https://inference.tinfoil.sh/v1/responses": 400 Bad Request {"message":"The \
        engine prompt length 227861 exceeds the max_model_len 131072. Please reduce \
        prompt.","type":"invalid_request_error","param":"input","code":400}
        """
        let explained = ChatViewModel.explainRawError(raw)
        #expect(explained?.contains("too long for the model") == true)
    }

    @Test @MainActor
    func mapsTimeoutToFriendlyMessage() {
        let explained = ChatViewModel.explainRawError("context deadline exceeded (Client.Timeout exceeded)")
        #expect(explained?.contains("took too long") == true)
    }

    @Test @MainActor
    func unknownErrorsHaveNoMapping() {
        #expect(ChatViewModel.explainRawError("some inscrutable failure") == nil)
    }
}
