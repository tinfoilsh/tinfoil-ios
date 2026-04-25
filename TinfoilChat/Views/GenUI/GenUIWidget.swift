//
//  GenUIWidget.swift
//  TinfoilChat
//
//  Generative UI widget abstraction. Mirrors the webapp's `GenUIWidget` so
//  widget definitions, tool-schema generation, runtime rendering, and the
//  prompt-hint block stay in lockstep across platforms.

import Foundation
import OpenAI
import SwiftUI

/// Where a widget renders.
///
/// - `inline`: inside the assistant message body in the chat scroll.
/// - `input`: replaces the `MessageInputView` until the user resolves it.
enum GenUIWidgetSurface {
    case inline
    case input
}

/// Read-only context passed to inline-surface widgets.
struct GenUIRenderContext {
    let isDarkMode: Bool
}

/// Context passed to input-surface widgets. The widget calls `resolve` to
/// submit a synthetic user message and `cancel` to dismiss without
/// answering.
struct GenUIInputContext {
    let toolCallId: String
    let isDarkMode: Bool
    let resolve: (_ resultText: String, _ resultData: JSONValue?) -> Void
    let cancel: (() -> Void)?
}

/// A single resolved choice for an input-surface widget. Serializes to the
/// same wire shape the webapp persists on `TimelineToolCallBlock.resolution`
/// — `resolvedAt` is encoded as milliseconds since epoch.
struct GenUIResolution: Codable, Equatable {
    let text: String
    let data: JSONValue?
    let resolvedAt: Date

    init(text: String, data: JSONValue?, resolvedAt: Date = Date()) {
        self.text = text
        self.data = data
        self.resolvedAt = resolvedAt
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case data
        case resolvedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
        if let millis = try? container.decode(Double.self, forKey: .resolvedAt) {
            resolvedAt = Date(timeIntervalSince1970: millis / 1000.0)
        } else if let date = try? container.decode(Date.self, forKey: .resolvedAt) {
            resolvedAt = date
        } else if let dateString = try? container.decode(String.self, forKey: .resolvedAt),
                  let parsed = ISO8601DateFormatter().date(from: dateString) {
            resolvedAt = parsed
        } else {
            resolvedAt = Date()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(data, forKey: .data)
        let millis = resolvedAt.timeIntervalSince1970 * 1000.0
        try container.encode(millis, forKey: .resolvedAt)
    }
}

/// Erased widget protocol used by the registry. Concrete widgets conform via
/// `GenUIWidget` which adds typed `Args` decoding.
protocol AnyGenUIWidget {
    var name: String { get }
    var description: String { get }
    var schema: JSONSchema { get }
    var surface: GenUIWidgetSurface { get }
    var promptHint: String { get }

    /// Returns true if `rawArgs` parse + validate against the widget's
    /// schema. Used to decide whether to show a real widget or a parse
    /// failure card.
    func canRender(rawArgs: Data) -> Bool

    /// Inline render. Widgets with `surface == .input` return `nil`.
    @MainActor
    func renderInline(rawArgs: Data, context: GenUIRenderContext) -> AnyView?

    /// Input-area render. Widgets with `surface == .inline` return `nil`.
    @MainActor
    func renderInputArea(rawArgs: Data, context: GenUIInputContext) -> AnyView?

    /// Compact stamp shown after the user resolves an input-surface widget.
    /// Returning `nil` means the widget leaves no trace.
    @MainActor
    func renderResolved(rawArgs: Data, resolution: GenUIResolution, context: GenUIRenderContext) -> AnyView?
}

/// Typed widget definition. Implementations decode the streamed JSON into
/// `Args` and render SwiftUI views with strong typing. Widgets are
/// registered via `GenUIRegistry.shared`.
protocol GenUIWidget: AnyGenUIWidget {
    associatedtype Args: Decodable

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView?

    @MainActor
    func renderInputArea(args: Args, context: GenUIInputContext) -> AnyView?

    @MainActor
    func renderResolved(args: Args, resolution: GenUIResolution, context: GenUIRenderContext) -> AnyView?
}

extension GenUIWidget {
    var surface: GenUIWidgetSurface { .inline }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? { nil }

    @MainActor
    func renderInputArea(args: Args, context: GenUIInputContext) -> AnyView? { nil }

    @MainActor
    func renderResolved(args: Args, resolution: GenUIResolution, context: GenUIRenderContext) -> AnyView? { nil }

    func canRender(rawArgs: Data) -> Bool {
        return decodeArgs(rawArgs) != nil
    }

    @MainActor
    func renderInline(rawArgs: Data, context: GenUIRenderContext) -> AnyView? {
        guard let args = decodeArgs(rawArgs) else { return nil }
        return renderInline(args: args, context: context)
    }

    @MainActor
    func renderInputArea(rawArgs: Data, context: GenUIInputContext) -> AnyView? {
        guard let args = decodeArgs(rawArgs) else { return nil }
        return renderInputArea(args: args, context: context)
    }

    @MainActor
    func renderResolved(rawArgs: Data, resolution: GenUIResolution, context: GenUIRenderContext) -> AnyView? {
        guard let args = decodeArgs(rawArgs) else { return nil }
        return renderResolved(args: args, resolution: resolution, context: context)
    }

    private func decodeArgs(_ data: Data) -> Args? {
        let decoder = JSONDecoder()
        return try? decoder.decode(Args.self, from: data)
    }
}

/// Helper for declaring an OpenAI function-tool JSON Schema in Swift using
/// the fork's `JSONSchema` type. Mirrors the shape Zod produces in the
/// webapp.
enum GenUISchema {
    static func object(
        properties: [String: JSONSchema],
        required: [String] = [],
        description: String? = nil
    ) -> JSONSchema {
        var fields: [JSONSchemaField] = [.type(.object), .properties(properties)]
        if !required.isEmpty {
            fields.append(.required(required))
        }
        if let description {
            fields.append(.description(description))
        }
        return JSONSchema(fields: fields)
    }

    static func string(description: String? = nil, enumValues: [String]? = nil) -> JSONSchema {
        var fields: [JSONSchemaField] = [.type(.string)]
        if let description { fields.append(.description(description)) }
        if let enumValues { fields.append(.enumValues(enumValues)) }
        return JSONSchema(fields: fields)
    }

    static func number(description: String? = nil) -> JSONSchema {
        var fields: [JSONSchemaField] = [.type(.number)]
        if let description { fields.append(.description(description)) }
        return JSONSchema(fields: fields)
    }

    static func integer(description: String? = nil) -> JSONSchema {
        var fields: [JSONSchemaField] = [.type(.integer)]
        if let description { fields.append(.description(description)) }
        return JSONSchema(fields: fields)
    }

    static func boolean(description: String? = nil) -> JSONSchema {
        var fields: [JSONSchemaField] = [.type(.boolean)]
        if let description { fields.append(.description(description)) }
        return JSONSchema(fields: fields)
    }

    static func array(items: JSONSchema, description: String? = nil, minItems: Int? = nil) -> JSONSchema {
        var fields: [JSONSchemaField] = [.type(.array), .items(items)]
        if let description { fields.append(.description(description)) }
        if let minItems { fields.append(.minItems(minItems)) }
        return JSONSchema(fields: fields)
    }

    /// `string | number` union — used by widgets like StatCards / SportsData.
    static func stringOrNumber(description: String? = nil) -> JSONSchema {
        var fields: [JSONSchemaField] = [.type(.types(["string", "number"]))]
        if let description { fields.append(.description(description)) }
        return JSONSchema(fields: fields)
    }
}

/// `Decodable` shim that accepts either a `String` or a numeric value and
/// surfaces a `String`. Mirrors the webapp's `z.union([z.string(), z.number()])`
/// idiom used by stats / sports-data fields.
struct StringOrNumber: Codable, Equatable {
    let stringValue: String
    let isNumber: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self.stringValue = String(intValue)
            self.isNumber = true
        } else if let doubleValue = try? container.decode(Double.self) {
            // Render integers without trailing ".0".
            if doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                self.stringValue = String(Int(doubleValue))
            } else {
                self.stringValue = String(doubleValue)
            }
            self.isNumber = true
        } else if let stringValue = try? container.decode(String.self) {
            self.stringValue = stringValue
            self.isNumber = false
        } else {
            throw DecodingError.typeMismatch(
                StringOrNumber.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected String or Number")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}
