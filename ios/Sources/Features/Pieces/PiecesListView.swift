// MARK: - PiecesListView
//
// All pieces, newest first. Each row shows mark number, status, family, and yard
// location. Tapping opens the read-only detail. Reached from HomeView.

import SwiftUI
import Supabase

struct PiecesListView: View {

    // MARK: - Properties

    @StateObject private var viewModel: PiecesListViewModel

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        _viewModel = StateObject(wrappedValue: PiecesListViewModel(client: client))
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("Pieces")
            .task {
                if case .idle = viewModel.state {
                    await viewModel.load()
                }
            }
            .refreshable {
                await viewModel.load()
            }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let pieces):
            if pieces.isEmpty {
                EmptyStateView(
                    title: "No pieces yet",
                    systemImage: "shippingbox",
                    message: "Create a piece from the Home screen to see it here."
                )
            } else {
                List(pieces) { piece in
                    NavigationLink {
                        PieceDetailView(piece: piece)
                    } label: {
                        PieceRow(piece: piece)
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

// MARK: - PieceRow

private struct PieceRow: View {

    let piece: PieceListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(piece.markNo)
                    .font(.headline)
                Spacer()
                PieceStatusBadge(status: piece.status)
            }
            Text(piece.familyName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let location = piece.yardLocation, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
