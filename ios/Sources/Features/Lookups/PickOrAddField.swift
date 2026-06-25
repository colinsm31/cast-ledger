// MARK: - PickOrAddField
//
// A reusable form row that lets the user pick an existing lookup value or add a
// new one. New values are saved to the shared list immediately (via LookupStore)
// and become available everywhere that uses the same kind. iOS 16-compatible
// (Menu + an "Add new" sheet rather than iOS 17 inline APIs).

import SwiftUI

struct PickOrAddField: View {

    // MARK: - Properties

    let title: String
    let kind: LookupKind
    @Binding var selection: String
    var allowsClearing: Bool = true

    @EnvironmentObject private var lookupStore: LookupStore
    @State private var isAddingNew = false

    // MARK: - Body

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            menu
        }
        .task {
            await lookupStore.loadIfNeeded(kind)
        }
        .sheet(isPresented: $isAddingNew) {
            AddLookupValueSheet(title: title) { newValue in
                Task {
                    let canonical = await lookupStore.add(newValue, to: kind)
                    if !canonical.isEmpty {
                        selection = canonical
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var menu: some View {
        Menu {
            ForEach(lookupStore.values(for: kind), id: \.self) { value in
                Button {
                    selection = value
                } label: {
                    if value == selection {
                        Label(value, systemImage: "checkmark")
                    } else {
                        Text(value)
                    }
                }
            }

            Divider()

            Button {
                isAddingNew = true
            } label: {
                Label("Add new…", systemImage: "plus")
            }

            if allowsClearing, !selection.isEmpty {
                Button(role: .destructive) {
                    selection = ""
                } label: {
                    Label("Clear", systemImage: "xmark")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.isEmpty ? "Choose" : selection)
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - AddLookupValueSheet

/// Small sheet to type a new lookup value. Saving is handled by the caller.
private struct AddLookupValueSheet: View {

    let title: String
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("New \(title.lowercased())") {
                    TextField("Value", text: $text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Add \(title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
