// MARK: - PiecesListViewModel
//
// Loads all pieces (with embedded design summary) for the list view.

import Foundation
import Supabase

@MainActor
final class PiecesListViewModel: ObservableObject {

    // MARK: - State

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([PieceListItem])
        case failed(String)
    }

    // MARK: - Properties

    @Published private(set) var state: LoadState = .idle

    private let repository: PieceListRepository

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.repository = PieceListRepository(client: client)
    }

    // MARK: - Actions

    func load() async {
        state = .loading
        do {
            let pieces = try await repository.fetchPieces()
            state = .loaded(pieces)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
