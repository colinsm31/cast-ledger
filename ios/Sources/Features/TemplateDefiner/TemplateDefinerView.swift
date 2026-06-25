// MARK: - TemplateDefinerView
//
// The spec-template definer — an engineer declares a product family and its
// fields. Family metadata at top; a dynamic, per-field editor below. On save it
// calls the atomic RPC via the view model and invokes `onSaved`.

import SwiftUI

struct TemplateDefinerView: View {

    // MARK: - Properties

    @StateObject private var viewModel: TemplateDefinerViewModel
    @Environment(\.dismiss) private var dismiss
    private let onSaved: () -> Void

    // MARK: - Lifecycle

    init(viewModel: TemplateDefinerViewModel, onSaved: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onSaved = onSaved
    }

    // MARK: - Body

    var body: some View {
        Form {
            familySection
            attributesSection
            if let message = viewModel.errorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("New Family")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if viewModel.isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        Task { await viewModel.save() }
                    }
                    .disabled(!viewModel.canSave)
                }
            }
        }
        .onChange(of: viewModel.didSave) { didSave in
            if didSave {
                onSaved()
            }
        }
    }

    // MARK: - Sections

    private var familySection: some View {
        Section("Family") {
            TextField("Drawing number (e.g. WP-DECK-STD)", text: $viewModel.draft.drawingNo)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            TextField("Family (e.g. Platform Deck Panel)", text: $viewModel.draft.family)
            TextField("Name (e.g. Standard Platform Deck Panel)", text: $viewModel.draft.name)
            Stepper("Revision \(viewModel.draft.revision)",
                    value: $viewModel.draft.revision, in: 1...999)
        }
    }

    private var attributesSection: some View {
        Section {
            ForEach($viewModel.draft.attributes) { $attribute in
                SpecAttributeEditor(attribute: $attribute)
            }
            .onDelete { offsets in
                viewModel.removeAttributes(at: offsets)
            }

            Button {
                viewModel.addAttribute()
            } label: {
                Label("Add field", systemImage: "plus.circle")
            }
        } header: {
            Text("Spec fields")
        } footer: {
            if let message = viewModel.validationError {
                Text(message).foregroundStyle(.secondary)
            } else {
                Text("These fields drive the piece editor's form and QC gating.")
            }
        }
    }
}

// MARK: - SpecAttributeEditor

/// Per-attribute editor row. Shows min/max for numbers and a values field for
/// enums, conditionally on the chosen type.
private struct SpecAttributeEditor: View {

    @Binding var attribute: DraftSpecAttribute

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Field name — pick an existing name or add a new one to the shared list.
            PickOrAddField(
                title: "Field name",
                kind: .fieldName,
                selection: $attribute.name,
                allowsClearing: false
            )

            Picker("Type", selection: $attribute.valueType) {
                ForEach(Self.selectableTypes, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)

            // Unit — shared lookup; optional, so clearing is allowed.
            PickOrAddField(
                title: "Unit",
                kind: .unit,
                selection: $attribute.unit
            )

            if attribute.valueType == .number {
                HStack {
                    TextField("Min", text: $attribute.validMin)
                        .keyboardType(.decimalPad)
                    TextField("Max", text: $attribute.validMax)
                        .keyboardType(.decimalPad)
                }
            }

            if attribute.valueType == .enumeration {
                EnumValuesEditor(values: $attribute.enumValues)
            }

            Toggle("Required", isOn: $attribute.required)
            Toggle("QC gate", isOn: $attribute.qcGate)

            if let error = attribute.validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    // Types a user can pick in the definer. `ref`/`unknown` are excluded for MVP.
    static let selectableTypes: [SpecValueType] = [
        .number, .text, .enumeration, .bool, .list
    ]
}

// MARK: - EnumValuesEditor

/// Builds an enum's allowed values from the shared enum-value lookup. Picking a
/// value appends it (if not already present); chips show the chosen set and can
/// be removed.
private struct EnumValuesEditor: View {

    @Binding var values: [String]
    @State private var pendingValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allowed values")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !values.isEmpty {
                // Simple wrapping chips via a vertical list of horizontal groups
                // is overkill here; a plain flow of labeled buttons reads fine.
                ForEach(values, id: \.self) { value in
                    HStack {
                        Text(value)
                        Spacer()
                        Button(role: .destructive) {
                            values.removeAll { $0 == value }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Pick or add a value; appending happens via onChange of the binding.
            PickOrAddField(
                title: "Add value",
                kind: .enumValue,
                selection: $pendingValue,
                allowsClearing: false
            )
            .onChange(of: pendingValue) { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if !values.contains(trimmed) {
                    values.append(trimmed)
                }
                pendingValue = ""   // reset so the same value can be re-picked elsewhere
            }
        }
    }
}

// MARK: - SpecValueType display

private extension SpecValueType {
    var displayName: String {
        switch self {
        case .number:      return "Number"
        case .text:        return "Text"
        case .enumeration: return "Enum"
        case .bool:        return "Yes / No"
        case .ref:         return "Reference"
        case .list:        return "List"
        case .unknown:     return "Unknown"
        }
    }
}
