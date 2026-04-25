//
//  TimelineToolCalls.swift
//  TinfoilChat
//
//  Helpers for reading and writing GenUI tool-call blocks on the
//  message timeline. The timeline is the cross-platform wire format
//  the webapp persists on `Message.timeline`; this file keeps iOS in
//  lockstep so chats round-trip cleanly between platforms.
//
//  Wire shape (per webapp `TimelineToolCallBlock`):
//      {
//        "type": "tool_call",
//        "id": "tool-call-3",
//        "toolCallId": "<provider-id>",
//        "name": "render_bar_chart",
//        "arguments": "<accumulated JSON>",
//        "resolvedAt": 1714060800000,                  // optional, ms epoch
//        "resolution": { "text": "...", "data": ... } // optional
//      }

import Foundation

enum TimelineToolCalls {
    /// Reads the resolution off a tool_call block keyed by `toolCallId`.
    /// Returns `nil` if the block isn't found or hasn't been resolved.
    /// The timestamp lives at the block level (`resolvedAt`) on the
    /// wire while `text` and `data` live in the inner `resolution`
    /// object — this helper reunites them.
    static func resolution(in timeline: [JSONValue]?, toolCallId: String) -> GenUIResolution? {
        guard let timeline else { return nil }
        for block in timeline {
            guard let object = block.objectValue,
                  object["type"]?.stringValue == "tool_call",
                  object["toolCallId"]?.stringValue == toolCallId else { continue }
            guard let resolvedAtMillis = object["resolvedAt"]?.numberValue else { return nil }
            let inner = object["resolution"]?.objectValue ?? [:]
            let text = inner["text"]?.stringValue ?? ""
            return GenUIResolution(
                text: text,
                data: inner["data"],
                resolvedAt: Date(timeIntervalSince1970: resolvedAtMillis / 1000.0)
            )
        }
        return nil
    }

    /// Inserts or replaces the tool_call block for the given
    /// `toolCallId` with the latest accumulated `arguments`. Blocks are
    /// matched by `toolCallId`; new blocks are appended in stream order.
    static func upsertStreamingBlock(
        in timeline: inout [JSONValue],
        toolCallId: String,
        name: String,
        arguments: String
    ) {
        let index = timeline.firstIndex { block in
            guard let object = block.objectValue else { return false }
            return object["type"]?.stringValue == "tool_call"
                && object["toolCallId"]?.stringValue == toolCallId
        }

        if let index {
            // Preserve any existing fields (e.g. id, resolvedAt) and only
            // update the streaming arguments / name.
            var existing = timeline[index].objectValue ?? [:]
            existing["arguments"] = .string(arguments)
            if !name.isEmpty { existing["name"] = .string(name) }
            timeline[index] = .object(existing)
            return
        }

        let block: [String: JSONValue] = [
            "type": .string("tool_call"),
            "id": .string("tool-call-\(timeline.count)"),
            "toolCallId": .string(toolCallId),
            "name": .string(name),
            "arguments": .string(arguments),
        ]
        timeline.append(.object(block))
    }

    /// Marks the matching tool_call block as resolved by writing the
    /// outer `resolvedAt` and the inner `resolution` object. Mirrors
    /// the webapp's `TimelineBuilder.resolveToolCall` shape exactly.
    static func resolve(
        in timeline: inout [JSONValue],
        toolCallId: String,
        text: String,
        data: JSONValue?,
        at date: Date = Date()
    ) {
        let millis = date.timeIntervalSince1970 * 1000.0
        for index in timeline.indices {
            guard var object = timeline[index].objectValue,
                  object["type"]?.stringValue == "tool_call",
                  object["toolCallId"]?.stringValue == toolCallId else { continue }
            object["resolvedAt"] = .number(millis)
            var inner: [String: JSONValue] = ["text": .string(text)]
            if let data { inner["data"] = data }
            object["resolution"] = .object(inner)
            timeline[index] = .object(object)
            return
        }
    }
}

extension JSONValue {
    /// Convenience accessor for numeric values.
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
