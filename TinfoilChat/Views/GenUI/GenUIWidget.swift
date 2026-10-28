//
//  GenUIWidget.swift
//  TinfoilChat
//
//  Generative UI widget abstraction. Mirrors the webapp's `GenUIWidget`:
//  how a widget decodes the arguments of the tool call that names it and
//  renders them. The chat service declares the tools to the model.

import Foundation
import SwiftUI

/// Read-only context passed to widgets as they render in a reply.
struct GenUIRenderContext {
    let isDarkMode: Bool
}

/// Erased widget protocol used by the registry. Concrete widgets conform via
/// `GenUIWidget` which adds typed `Args` decoding.
protocol AnyGenUIWidget {
    var name: String { get }

    /// Returns true if `rawArgs` parse + validate against the widget's
    /// schema. Used to decide whether to show a real widget or a parse
    /// failure card.
    func canRender(rawArgs: Data) -> Bool

    func argumentValidationError(rawArgs: Data) -> GenUIArgumentValidationError?

    /// The widget as it renders in the reply.
    @MainActor
    func renderInline(rawArgs: Data, context: GenUIRenderContext) -> AnyView?
}

/// Typed widget definition. Implementations decode the streamed JSON into
/// `Args` and render SwiftUI views with strong typing. Widgets are
/// registered via `GenUIRegistry.shared`.
protocol GenUIWidget: AnyGenUIWidget {
    associatedtype Args: Decodable

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView?
}

extension GenUIWidget {
    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? { nil }

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
