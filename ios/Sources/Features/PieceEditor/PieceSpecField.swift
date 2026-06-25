// MARK: - PieceSpecField
//
// A single editable spec value on the piece form, built from a template's
// spec_attribute definition. Holds the user's input as text (uniform handling)
// and knows how to validate itself against the definition and emit a typed
// JSON value for the spec_values payload.

import Foundation

struct PieceSpecField: Identifiable {

    // MARK: - Properties

    let id: UUID
    let name: String
    let valueType: SpecValueType
    let unit: String?
    let required: Bool
    let validMin: Double?
    let validMax: Double?
    let enumValues: [String]

    /// User input. Text for number/text; the chosen case for enum; "true"/"false"
    /// for bool (driven by a toggle in the view).
    var input: String = ""

    // MARK: - Init from a spec_attribute

    init(attribute: SpecAttribute) {
        self.id = attribute.id
        self.name = attribute.name
        self.valueType = attribute.valueType
        self.unit = attribute.unit
        self.required = attribute.required
        self.validMin = attribute.validMin
        self.validMax = attribute.validMax
        self.enumValues = attribute.enumValues?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    // MARK: - Validation

    /// A user-facing problem with this field's value, or nil when valid.
    var validationError: String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return required ? "\(name) is required" : nil
        }

        switch valueType {
        case .number:
            guard let value = Double(trimmed) else {
                return "\(name) must be a number"
            }
            if let minimum = validMin, value < minimum {
                return "\(name) must be ≥ \(formatted(minimum))"
            }
            if let maximum = validMax, value > maximum {
                return "\(name) must be ≤ \(formatted(maximum))"
            }
        case .enumeration:
            if !enumValues.isEmpty, !enumValues.contains(trimmed) {
                return "\(name) must be one of: \(enumValues.joined(separator: ", "))"
            }
        case .bool, .text, .ref, .list, .unknown:
            break
        }
        return nil
    }

    // MARK: - JSON value for the payload

    /// The typed JSON value to store in spec_values, or nil to omit (empty optional).
    var jsonValue: JSONValue? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        switch valueType {
        case .number:
            return Double(trimmed).map { .number($0) }
        case .bool:
            return .bool(trimmed == "true")
        case .enumeration, .text, .ref, .list, .unknown:
            return .string(trimmed)
        }
    }

    // MARK: - Private Helpers

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
