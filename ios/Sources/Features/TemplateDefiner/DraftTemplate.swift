// MARK: - Draft template models
//
// In-progress (editable) representations used by the spec-template definer before
// it's saved. These are mutable, Identifiable for SwiftUI lists, and carry no
// server-assigned fields. On save they're encoded into the create_product_design
// RPC payload. Kept free of SwiftUI so the validation is unit-testable.

import Foundation

// MARK: - DraftSpecAttribute

/// One editable field definition within a template.
struct DraftSpecAttribute: Identifiable, Equatable {
    let id = UUID()
    var name: String = ""
    var valueType: SpecValueType = .number
    var unit: String = ""
    var required: Bool = false
    var qcGate: Bool = false
    var validMin: String = ""              // kept as text for free-form entry; parsed on save
    var validMax: String = ""
    var enumValues: [String] = []          // discrete values, only used for .enumeration

    // MARK: - Validation

    /// A user-facing problem with this attribute, or nil when valid.
    var validationError: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "Field name is required"
        }

        if valueType == .number {
            if !validMin.isEmpty, Double(validMin) == nil {
                return "\(trimmedName): min must be a number"
            }
            if !validMax.isEmpty, Double(validMax) == nil {
                return "\(trimmedName): max must be a number"
            }
            if let lower = Double(validMin), let upper = Double(validMax), lower > upper {
                return "\(trimmedName): min cannot exceed max"
            }
        }

        if valueType == .enumeration, parsedEnumValues.isEmpty {
            return "\(trimmedName): an enum needs at least one value"
        }

        return nil
    }

    /// Enum values, trimmed and de-blanked (the discrete list the user built).
    var parsedEnumValues: [String] {
        enumValues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - DraftProductDesign

/// An editable product family (template) plus its attributes.
struct DraftProductDesign {
    var drawingNo: String = ""
    var family: String = ""
    var name: String = ""
    var revision: Int = 1
    var attributes: [DraftSpecAttribute] = []

    // MARK: - Validation

    /// The first user-facing problem with the whole draft, or nil when ready to save.
    var validationError: String? {
        if drawingNo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Drawing number is required"
        }
        if family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Family is required"
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Name is required"
        }
        if attributes.isEmpty {
            return "Add at least one spec field"
        }
        if let firstAttributeError = attributes.compactMap(\.validationError).first {
            return firstAttributeError
        }
        // Duplicate field names would collide on the unique (owner, name) index.
        let names = attributes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if Set(names).count != names.count {
            return "Field names must be unique"
        }
        return nil
    }

    var isValid: Bool {
        validationError == nil
    }
}
