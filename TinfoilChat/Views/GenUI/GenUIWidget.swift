//
//  GenUIWidget.swift
//  TinfoilChat
//
//  Generative UI widget abstraction. Mirrors the webapp's `GenUIWidget`:
//  how a widget decodes the arguments of the tool call that names it and
//  renders them. The chat service declares the tools to the model.

import Foundation
import SwiftUI

/// Where a widget renders.
///
/// - `inline`: inside the assistant message body in the chat scroll.
/// - `input`: replaces the `MessageInputView` until the user resolves it.
/// - `artifact`: compact inline summary plus a dedicated artifact surface
///   (reserved for future widgets; currently treated like `inline`).
enum GenUIWidgetSurface {
    case inline
    case input
    case artifact
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

/// A single resolved choice for an input-surface widget. Mirrors the data
/// the webapp passes to `widget.renderResolved(args, resolution)`. The
/// canonical persisted shape lives on `TimelineToolCallBlock` (block-level
/// `resolvedAt` + inner `resolution { text, data }`); see
/// `TimelineToolCalls` for serialization helpers. This struct is the
/// in-memory view used by widget render code.
struct GenUIResolution: Equatable {
    let text: String
    let data: JSONValue?
    let resolvedAt: Date

    init(text: String, data: JSONValue?, resolvedAt: Date = Date()) {
        self.text = text
        self.data = data
        self.resolvedAt = resolvedAt
    }
}

/// Erased widget protocol used by the registry. Concrete widgets conform via
/// `GenUIWidget` which adds typed `Args` decoding.
protocol AnyGenUIWidget {
    var name: String { get }
    var surface: GenUIWidgetSurface { get }

    /// Returns true if `rawArgs` parse + validate against the widget's
    /// schema. Used to decide whether to show a real widget or a parse
    /// failure card.
    func canRender(rawArgs: Data) -> Bool

    func argumentValidationError(rawArgs: Data) -> GenUIArgumentValidationError?

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
        return argumentValidationError(rawArgs: rawArgs) == nil
    }

    func argumentValidationError(rawArgs: Data) -> GenUIArgumentValidationError? {
        do {
            _ = try JSONDecoder().decode(Args.self, from: rawArgs)
            return nil
        } catch let error as DecodingError {
            return .widgetDecoding(codingPath: GenUIArgumentValidationError.codingPath(from: error))
        } catch {
            return .widgetDecoding(codingPath: "$")
        }
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

enum GenUIArgumentValidationError: Equatable {
    case invalidJSONObject
    case widgetDecoding(codingPath: String)

    fileprivate static func codingPath(from error: DecodingError) -> String {
        let codingPath: [CodingKey]
        switch error {
        case .dataCorrupted(let context),
             .typeMismatch(_, let context),
             .valueNotFound(_, let context):
            codingPath = context.codingPath
        case .keyNotFound(let key, let context):
            codingPath = context.codingPath + [key]
        @unknown default:
            codingPath = []
        }

        return codingPath.reduce(into: "$") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else if key.stringValue.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }) {
                path += ".\(key.stringValue)"
            } else {
                path += ".<field>"
            }
        }
    }
}

enum GenUIRetryState: Equatable {
    case generating
    case requestFailed
    case staleOrigin
}

enum GenUIArgumentValidator {
    static func validationError(
        rawArgs: Data,
        widget: any AnyGenUIWidget
    ) -> GenUIArgumentValidationError? {
        guard let json = try? JSONSerialization.jsonObject(with: rawArgs),
              json is [String: Any] else {
            return .invalidJSONObject
        }
        return widget.argumentValidationError(rawArgs: rawArgs)
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
            if doubleValue.isFinite,
               doubleValue >= Double(Int.min),
               doubleValue <= Double(Int.max),
               doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
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
