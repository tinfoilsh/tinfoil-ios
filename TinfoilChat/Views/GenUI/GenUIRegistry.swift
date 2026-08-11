//
//  GenUIRegistry.swift
//  TinfoilChat
//
//  Central registry of every renderable widget. Adding a widget is one
//  Swift file under `Widgets/` plus one entry in `widgets`.

import Foundation
import OpenAI

@MainActor
final class GenUIRegistry {
    static let shared = GenUIRegistry()

    /// Order influences only the order of prompt hints presented to the
    /// model. Keep frequently-useful widgets near the top so the model
    /// reaches for them first.
    let widgets: [AnyGenUIWidget] = [
        StatCardsWidget(),
        TimelineWidget(),
        ChartWidget(),
        ImageWidget(),
        LinkPreviewWidget(),
        ArtifactPreviewWidget(),
        ClockWidget(),
        RecipeCardWidget(),
        MessageComposeWidget(),
        SportsDataWidget(),
        MapWidget(),
    ]

    private lazy var widgetsByName: [String: AnyGenUIWidget] = {
        var dict: [String: AnyGenUIWidget] = [:]
        for widget in widgets {
            dict[widget.name] = widget
        }
        return dict
    }()

    /// Lookup by tool name.
    func widget(named name: String) -> AnyGenUIWidget? {
        widgetsByName[name]
    }

    /// True when `name` corresponds to a registered widget.
    func isGenUIToolName(_ name: String) -> Bool {
        widgetsByName[name] != nil
    }

    /// Build the OpenAI `tools` array used on chat completion requests.
    /// Each GenUI tool is flagged with the router's auto-continue header
    /// so the model produces a single coherent turn (tool call followed
    /// by surrounding prose) instead of ending at the tool boundary.
    func buildToolParams() -> [ChatQuery.ChatCompletionToolParam] {
        widgets.map { widget in
            ChatQuery.ChatCompletionToolParam(
                function: .init(
                    name: widget.name,
                    description: widget.description,
                    parameters: widget.schema,
                    strict: nil,
                    extra: [
                        "x-tinfoil-tool-auto-continue": .bool(true),
                    ]
                )
            )
        }
    }

    /// Build the system-prompt hint block describing all registered
    /// widgets. Mirrors `buildGenUIPromptHint()` on the webapp side.
    func buildPromptHint() -> String {
        let header =
            "You have optional render_* tools available. Default to a normal markdown " +
            "response. Only call a render_* tool when the user explicitly asks for " +
            "one of these UI elements, or when the content genuinely cannot be " +
            "expressed well in markdown (e.g. an interactive HTML page, a chart that " +
            "requires plotting, an embedded live preview). Do not use render_* tools " +
            "for ordinary informational answers, lists, tables, or summaries — write " +
            "those as regular prose and markdown. Prefer at most one render_* call " +
            "per response, and always pair it with a written answer rather than " +
            "replacing the answer with a widget."
        let lines = widgets.map { "- \($0.name): \($0.promptHint)" }
        return header + "\n" + lines.joined(separator: "\n")
    }
}
