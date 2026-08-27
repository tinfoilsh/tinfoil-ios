//
//  GenUIConfigTests.swift
//  TinfoilChatTests
//

import Foundation
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "GenUIConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func response(header: String = "Remote guidance", widgets: String) -> Data {
        Data(
            """
            {"genUI":{"header":"\(header)","enabledWidgets":\(widgets)}}
            """.utf8
        )
    }

    private func makeService(
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        state: LoaderState
    ) -> GenUIConfigService {
        GenUIConfigService(defaults: defaults, now: now, dataLoader: state.load)
    }

    @Test func noConfigExposesEveryLocalWidget() {
        let state = LoaderState(result: .failure(LoaderError.offline))
        let service = makeService(defaults: makeDefaults(), state: state)
        let registry = GenUIRegistry(configService: service)

        #expect(registry.effectiveWidgets.count == registry.widgets.count)
    }

    @Test func subsetFiltersToolsAndPromptHints() async throws {
        let state = LoaderState(result: .success((response(
            widgets: #"["render_stat_cards","render_chart"]"#
        ), 200)))
        let service = makeService(defaults: makeDefaults(), state: state)
        await service.refresh()
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

    @Test func emptyAllowlistRemovesAllRequestCapabilities() async {
        let state = LoaderState(result: .success((response(widgets: "[]"), 200)))
        let service = makeService(defaults: makeDefaults(), state: state)
        await service.refresh()
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

    @Test func unknownWidgetNamesAreIgnored() async {
        let state = LoaderState(result: .success((response(
            widgets: #"["render_chart","render_future_widget"]"#
        ), 200)))
        let service = makeService(defaults: makeDefaults(), state: state)
        await service.refresh()
        let registry = GenUIRegistry(configService: service)

        #expect(registry.effectiveWidgets.map(\.name) == ["render_chart"])
    }

    @Test func malformedSuccessfulPayloadFallsBackToLocalWidgets() async {
        let defaults = makeDefaults()
        let state = LoaderState(result: .success((response(widgets: #"["render_chart"]"#), 200)))
        let service = makeService(defaults: defaults, state: state)
        await service.refresh()
        state.result = .success((Data(#"{"genUI":{"header":42,"enabledWidgets":"oops"}}"#.utf8), 200))

        await service.refresh()

        let registry = GenUIRegistry(configService: service)
        #expect(service.config == nil)
        #expect(registry.effectiveWidgets.count == registry.widgets.count)
        #expect(defaults.data(forKey: Constants.Config.genUIConfigCacheKey) == nil)
    }

    @Test func validCacheLoadsForUpToSevenDays() async {
        let cachedAt = Date(timeIntervalSince1970: 1_000_000)
        let defaults = makeDefaults()
        let state = LoaderState(result: .success((response(widgets: #"["render_chart"]"#), 200)))
        let writer = makeService(defaults: defaults, now: { cachedAt }, state: state)
        await writer.refresh()

        let cached = makeService(
            defaults: defaults,
            now: { cachedAt.addingTimeInterval(Constants.Config.genUIConfigCacheMaxAge) },
            state: LoaderState(result: .failure(LoaderError.offline))
        )
        let expired = makeService(
            defaults: defaults,
            now: { cachedAt.addingTimeInterval(Constants.Config.genUIConfigCacheMaxAge + 1) },
            state: LoaderState(result: .failure(LoaderError.offline))
        )

        #expect(cached.config?.enabledWidgets == ["render_chart"])
        #expect(expired.config == nil)
    }

    @Test func networkFailureRetainsInMemoryConfiguration() async {
        let state = LoaderState(result: .success((response(widgets: #"["render_chart"]"#), 200)))
        let service = makeService(defaults: makeDefaults(), state: state)
        await service.refresh()
        state.result = .failure(LoaderError.offline)

        await service.refresh()

        #expect(service.config?.enabledWidgets == ["render_chart"])
    }

    @Test func disabledWidgetsRemainAvailableForHistoricalRendering() async {
        let state = LoaderState(result: .success((response(widgets: "[]"), 200)))
        let service = makeService(defaults: makeDefaults(), state: state)
        await service.refresh()
        let registry = GenUIRegistry(configService: service)

        #expect(registry.effectiveWidgets.isEmpty)
        #expect(registry.widget(named: "render_chart") != nil)
        #expect(registry.isGenUIToolName("render_chart"))
    }
}
