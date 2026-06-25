// MARK: - PieceEditorView
//
// The piece clone-and-edit editor. The chosen design's template drives the spec
// fields (right control + validation per type); universal fields capture mark
// number, project, weight, and yard location. Saves a piece via the RPC.

import SwiftUI

struct PieceEditorView: View {

    // MARK: - Properties

    @StateObject private var viewModel: PieceEditorViewModel
    @EnvironmentObject private var lookupStore: LookupStore
    @Environment(\.dismiss) private var dismiss

    // MARK: - Lifecycle

    init(viewModel: PieceEditorViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle(viewModel.design.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            .task {
                if viewModel.loadState == .loading {
                    await viewModel.load()
                }
            }
            .onChange(of: viewModel.didSave) { didSave in
                if didSave { dismiss() }
            }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView("Loading template…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            EmptyStateView(
                title: "Couldn't load template",
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Retry",
                action: { Task { await viewModel.load() } }
            )

        case .ready:
            form
        }
    }

    private var form: some View {
        Form {
            identitySection
            specSection
            if let message = viewModel.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red).font(.callout)
                }
            }
        }
    }

    private var identitySection: some View {
        Section("Piece") {
            TextField("Mark number (e.g. EVG-D14)", text: $viewModel.markNo)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)

            Picker("Project", selection: $viewModel.selectedProjectID) {
                Text("Unassigned").tag(UUID?.none)
                ForEach(viewModel.projects) { project in
                    Text(project.jobNumber).tag(UUID?.some(project.id))
                }
            }

            TextField("Weight (lb, optional)", text: $viewModel.weightInput)
                .keyboardType(.decimalPad)

            TextField("Yard location (optional, e.g. Row C-7)", text: $viewModel.yardLocation)
        }
    }

    private var specSection: some View {
        Section {
            ForEach($viewModel.specFields) { $field in
                PieceSpecFieldEditor(field: $field)
            }
        } header: {
            Text("Specs")
        } footer: {
            if let message = viewModel.validationError {
                Text(message).foregroundStyle(.secondary)
            } else {
                Text("Fields and validation come from the \(viewModel.design.family) template.")
            }
        }
    }
}

// MARK: - PieceSpecFieldEditor

/// Renders the right control for one spec field based on its template type.
private struct PieceSpecFieldEditor: View {

    @Binding var field: PieceSpecField

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label

            switch field.valueType {
            case .number:
                TextField(field.unit ?? "Value", text: $field.input)
                    .keyboardType(.decimalPad)

            case .enumeration:
                if field.enumValues.isEmpty {
                    TextField("Value", text: $field.input)
                } else {
                    Picker(field.name, selection: $field.input) {
                        Text("Choose").tag("")
                        ForEach(field.enumValues, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

            case .bool:
                Toggle("Yes", isOn: boolBinding)

            case .text, .ref, .list, .unknown:
                TextField("Value", text: $field.input)
            }

            if let error = field.validationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Subviews

    private var label: some View {
        HStack(spacing: 4) {
            Text(field.name).font(.subheadline.weight(.medium))
            if let unit = field.unit, !unit.isEmpty {
                Text("(\(unit))").font(.caption).foregroundStyle(.secondary)
            }
            if field.required {
                Text("required").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    // Bool fields store "true"/"false" text; bridge to a Bool toggle.
    private var boolBinding: Binding<Bool> {
        Binding(
            get: { field.input == "true" },
            set: { field.input = $0 ? "true" : "false" }
        )
    }
}
