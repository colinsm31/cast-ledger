// MARK: - PieceFamilyPickerView
//
// Entry point to the piece editor: pick the family/design to clone from. Tapping
// a design pushes the template-driven PieceEditorView. Reached from HomeView.

import SwiftUI
import Supabase

struct PieceFamilyPickerView: View {

    // MARK: - Properties

    private let client: SupabaseClient
    @StateObject private var viewModel: TemplateListViewModel
    @StateObject private var lookupStore: LookupStore

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.client = client
        _viewModel = StateObject(wrappedValue: TemplateListViewModel(client: client))
        _lookupStore = StateObject(wrappedValue: LookupStore(client: client))
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("New Piece")
            .task {
                if case .idle = viewModel.state {
                    await viewModel.load()
                }
            }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let designs):
            if designs.isEmpty {
                EmptyStateView(
                    title: "No families yet",
                    systemImage: "square.stack.3d.up",
                    message: "Define a product family first, then create pieces against it."
                )
            } else {
                List(designs) { design in
                    NavigationLink {
                        PieceEditorView(
                            viewModel: PieceEditorViewModel(design: design, client: client)
                        )
                        .environmentObject(lookupStore)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(design.name).font(.headline)
                            Text("\(design.family) · \(design.drawingNo) · rev \(design.revision)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

        case .failed(let message):
            EmptyStateView(
                title: "Couldn't load",
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Retry",
                action: { Task { await viewModel.load() } }
            )
        }
    }
}
