//
//  GenUIConfigTests.swift
//  TinfoilChatTests
//

import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

@MainActor
struct GenUIConfigTests {
    private enum LoaderError: Error {
        case offline
    }

    private final class LoaderState {
        var result: Result<(Data, Int), Error>

        init(result: Result<(Data, Int), Error>) {
            self.result = result
        }

        func load(_ url: URL) async throws -> (Data, Int) {
            try result.get()
        }
    }

    private func response(header: String = "Remote guidance", widgets: String) -> Data {
        Data(
            """
            {"genUI":{"header":"\(header)","enabledWidgets":\(widgets)}}
            """.utf8
        )
    }

    private func makeService(state: LoaderState) -> GenUIConfigService {
        GenUIConfigService(dataLoader: state.load)
    }

    @Test func noConfigExposesNoWidgetsOrHint() {
        let state = LoaderState(result: .failure(LoaderError.offline))
        let service = makeService(state: state)
        let registry = GenUIRegistry(configService: service)

        #expect(registry.effectiveWidgets.isEmpty)
        #expect(registry.buildToolParams().isEmpty)
        #expect(registry.buildPromptHint() == nil)
    }

    @Test func subsetFiltersToolsAndPromptHints() async throws {
        let state = LoaderState(result: .success((response(
            widgets: #"["render_stat_cards","render_chart"]"#
        ), 200)))
        let service = makeService(state: state)
        try await service.refresh()
        let registry = GenUIRegistry(configService: service)

        #expect(registry.effectiveWidgets.map(\.name) == ["render_stat_cards", "render_chart"])
        #expect(registry.buildToolParams().count == 2)
        let hint = try #require(registry.buildPromptHint())
        #expect(hint.hasPrefix("Remote guidance\n"))
        #expect(hint.contains("render_stat_cards"))
        #expect(!hint.contains("render_timeline"))

        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "Base prompt",
            rules: "",
            conversationMessages: [],
            genUIRegistry: registry
        )
        #expect(query.tools?.count == 2)
        #expect(query.toolChoice == .auto)
        #expect(query.parallelToolCalls == nil)
    }

    @Test func emptyAllowlistRemovesAllRequestCapabilities() async throws {
        let state = LoaderState(result: .success((response(widgets: "[]"), 200)))
        let service = makeService(state: state)
        try await service.refresh()
        let registry = GenUIRegistry(configService: service)
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "Base prompt",
            rules: "",
            conversationMessages: [],
            genUIRegistry: registry
        )

        #expect(registry.buildPromptHint() == nil)
        #expect(query.tools == nil)
        #expect(query.toolChoice == nil)
        #expect(query.parallelToolCalls == nil)
    }

    @Test func unknownWidgetNamesAreIgnored() async throws {
        let state = LoaderState(result: .success((response(
            widgets: #"["render_chart","render_future_widget"]"#
        ), 200)))
        let service = makeService(state: state)
        try await service.refresh()
        let registry = GenUIRegistry(configService: service)

        #expect(registry.effectiveWidgets.map(\.name) == ["render_chart"])
    }

    @Test func malformedPayloadThrowsAndRetainsPreviousConfig() async throws {
        let state = LoaderState(result: .success((response(widgets: #"["render_chart"]"#), 200)))
        let service = makeService(state: state)
        try await service.refresh()
        state.result = .success((Data(#"{"genUI":{"header":42,"enabledWidgets":"oops"}}"#.utf8), 200))

        await #expect(throws: GenUIConfigError.self) {
            try await service.refresh()
        }
        #expect(service.config?.enabledWidgets == ["render_chart"])
    }

    @Test func nonSuccessStatusThrows() async {
        let state = LoaderState(result: .success((response(widgets: #"["render_chart"]"#), 503)))
        let service = makeService(state: state)

        await #expect(throws: GenUIConfigError.self) {
            try await service.refresh()
        }
        #expect(service.config == nil)
    }

    @Test func networkFailurePropagatesAndRetainsInMemoryConfiguration() async throws {
        let state = LoaderState(result: .success((response(widgets: #"["render_chart"]"#), 200)))
        let service = makeService(state: state)
        try await service.refresh()
        state.result = .failure(LoaderError.offline)

        await #expect(throws: LoaderError.self) {
            try await service.refresh()
        }
        #expect(service.config?.enabledWidgets == ["render_chart"])
    }

    @Test func disabledWidgetsRemainAvailableForHistoricalRendering() async throws {
        let state = LoaderState(result: .success((response(widgets: "[]"), 200)))
        let service = makeService(state: state)
        try await service.refresh()
        let registry = GenUIRegistry(configService: service)

        #expect(registry.effectiveWidgets.isEmpty)
        #expect(registry.widget(named: "render_chart") != nil)
        #expect(registry.isGenUIToolName("render_chart"))
    }
}
