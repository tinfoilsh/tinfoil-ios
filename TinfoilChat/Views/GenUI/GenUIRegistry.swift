//
//  GenUIRegistry.swift
//  TinfoilChat
//
//  Central registry of every renderable widget. Adding a widget is one
//  Swift file under `Widgets/` plus one entry in `widgets`.

import Foundation

@MainActor
final class GenUIRegistry {
    static let shared = GenUIRegistry()

    /// Every widget this client renders. The chat service offers the model
    /// those of them its session names.
    let widgets: [AnyGenUIWidget]

    init(
        widgets: [AnyGenUIWidget] = [
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
    ) {
        self.widgets = widgets
    }

    private lazy var widgetsByName: [String: AnyGenUIWidget] = {
        var dict: [String: AnyGenUIWidget] = [:]
        for widget in widgets {
            dict[widget.name] = widget
        }
        return dict
    }()

    /// The names of the widgets this client renders, which a turn sends.
    static var widgetNames: [String] { shared.widgets.map(\.name) }

    /// Lookup by tool name.
    func widget(named name: String) -> AnyGenUIWidget? {
        widgetsByName[name]
    }

    static func widget(named name: String) -> AnyGenUIWidget? {
        shared.widget(named: name)
    }

    /// True when `name` corresponds to a registered widget.
    func isGenUIToolName(_ name: String) -> Bool {
        widgetsByName[name] != nil
    }
}
