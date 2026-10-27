import Foundation

/// A JSON object as a request names it, with members this client sets to
/// null where the protocol gives null a meaning.
struct JSONObject: Encodable, Sendable {
    private let members: [String: JSONValue]

    init(_ members: [String: JSONValue]) {
        self.members = members
    }

    /// A JSON object from values as JSONSerialization reads them.
    init(_ object: [String: Any]) {
        members = object.mapValues(JSONValue.init(any:))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (name, value) in members.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: Key(name))
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

extension JSONValue {
    /// A value as JSONSerialization reads it.
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let list as [Any]: self = .array(list.map(JSONValue.init(any:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }
}

/// JSON kept as its bytes and written back as they are.
struct RawJSON: Codable, Equatable, Sendable {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(AnyJSON.self)
        data = try JSONSerialization.data(withJSONObject: value.value, options: [.fragmentsAllowed, .sortedKeys])
    }

    func encode(to encoder: any Encoder) throws {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        try AnyJSON(value).encode(to: encoder)
    }
}

/// Any JSON value, as JSONSerialization reads and writes it, carried
/// through Codable.
struct AnyJSON: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int64.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyJSON].self) { value = array.map(\.value) }
        else if let object = try? container.decode([String: AnyJSON].self) { value = object.mapValues(\.value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value") }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let bool as Bool: try container.encode(bool)
        case let int as Int64: try container.encode(int)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map(AnyJSON.init))
        case let object as [String: Any]: try container.encode(object.mapValues(AnyJSON.init))
        default: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Not a JSON value"))
        }
    }
}

extension Encodable {
    /// The value as a JSON object, as JSONSerialization reads it.
    func jsonObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Not a JSON object"))
        }
        return object
    }
}

extension Decodable {
    /// The value read from a JSON object, as JSONSerialization writes it.
    init(jsonObject: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}
