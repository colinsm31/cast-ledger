// MARK: - TemplateListView
//
// Lists product families (designs) and provides entry to the definer to create a
// new one. Reached from HomeView.

import SwiftUI
import Supabase

struct TemplateListView: View {

    // MARK: - Properties

    @StateObject private var viewModel: TemplateListViewModel
    @StateObject private var lookupStore: LookupStore
    @State private var isPresentingDefiner = false

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        _viewModel = StateObject(wrappedValue: TemplateListViewModel(client: client))
        _lookupStore = StateObject(wrappedValue: LookupStore(client: client))
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("Product Families")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingDefiner = true
                    } label: {
                        Label("New family", systemImage: "plus")
                    }
                }
            }
            .task {
                if case .idle = viewModel.state {
                    await viewModel.load()
                }
            }
            .sheet(isPresented: $isPresentingDefiner) {
                NavigationStack {
                    TemplateDefinerView(viewModel: viewModel.makeDefinerViewModel()) {
                        isPresentingDefiner = false
                        Task { await viewModel.load() }
                    }
                }
                .environmentObject(lookupStore)
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
                    message: "Tap + to define your first product family."
                )
            } else {
                List(designs) { design in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(design.name)
                            .font(.headline)
                        Text("\(design.family) · \(design.drawingNo) · rev \(design.revision)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
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
