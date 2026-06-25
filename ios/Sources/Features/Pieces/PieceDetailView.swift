// MARK: - PieceDetailView
//
// Read-only detail for a piece: identity, status, design + as-poured revision,
// weight, yard location, and its spec_values rendered from JSONB. The piece is
// passed in from the list (already loaded with its embedded design).

import SwiftUI

struct PieceDetailView: View {

    // MARK: - Properties

    let piece: PieceListItem

    // MARK: - Body

    var body: some View {
        List {
            identitySection
            designSection
            specSection
        }
        .navigationTitle(piece.markNo)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Piece") {
            LabeledRow(label: "Mark", value: piece.markNo)
            HStack {
                Text("Status")
                Spacer()
                PieceStatusBadge(status: piece.status)
            }
            if let weight = piece.weightLb {
                LabeledRow(label: "Weight", value: "\(formatted(weight)) lb")
            }
            if let location = piece.yardLocation, !location.isEmpty {
                LabeledRow(label: "Yard location", value: location)
            }
        }
    }

    private var designSection: some View {
        Section("Design") {
            LabeledRow(label: "Family", value: piece.familyName)
            LabeledRow(label: "Name", value: piece.designName)
            if let drawing = piece.productDesigns?.drawingNo {
                LabeledRow(label: "Drawing", value: drawing)
            }
            LabeledRow(label: "As-poured revision", value: "rev \(piece.productDesignRevision)")
        }
    }

    @ViewBuilder
    private var specSection: some View {
        Section("Specs") {
            let entries = specEntries
            if entries.isEmpty {
                Text("No spec values recorded.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.key) { entry in
                    LabeledRow(label: entry.key, value: entry.value)
                }
            }
        }
    }

    // MARK: - Spec rendering

    /// spec_values JSONB flattened to sorted (key, displayValue) pairs.
    private var specEntries: [(key: String, value: String)] {
        guard let object = piece.specValues.objectValue else {
            return []
        }
        return object
            .map { (key: $0.key, value: Self.display($0.value)) }
            .sorted { $0.key < $1.key }
    }

    private static func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): return string
        case .number(let number): return number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let bool):     return bool ? "Yes" : "No"
        case .null:               return "—"
        case .array(let array):   return array.map(display).joined(separator: ", ")
        case .object:             return "{…}"
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

// MARK: - LabeledRow

/// A simple label/value row (reused across the detail sections).
private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}
