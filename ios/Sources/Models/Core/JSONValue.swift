// MARK: - JSONValue
//
// A Codable representation of arbitrary JSON, used to map the schema's JSONB
// columns (spec_values, spec_template, default_components, as_built_components,
// recipe, enum_values) into Swift without forcing a fixed shape. This is the
// Swift side of the structured-flexible spec model: the relational core is
// strongly typed; the variable, family-specific data rides in JSONValue.
//
// Parse-don't-trust: decoding never force-unwraps and rejects malformed input
// with a typed DecodingError rather than crashing.

import Foundation

/// A value decoded from / encoded to arbitrary JSON.
enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    // MARK: - Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    // MARK: - Encoding

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    /// The wrapped string, when this value is a `.string`.
    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    /// The wrapped number, when this value is a `.number`.
    var doubleValue: Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }

    /// The wrapped number as an `Int`, when this value is a whole `.number`.
    var intValue: Int? {
        guard case .number(let value) = self else {
            return nil
        }
        return Int(value)
    }

    /// The wrapped bool, when this value is a `.bool`.
    var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    /// The wrapped object, when this value is an `.object`.
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    /// The wrapped array, when this value is an `.array`.
    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    /// True when this value is JSON `null`.
    var isNull: Bool {
        self == .null
    }

    /// Subscript into an object value by key.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
