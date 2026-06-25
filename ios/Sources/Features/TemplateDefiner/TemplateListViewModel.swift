// MARK: - TemplateListViewModel
//
// Lists existing product designs (families). The definer screen pushes onto this
// list and, on successful save, asks it to refresh.

import Foundation
import Supabase

@MainActor
final class TemplateListViewModel: ObservableObject {

    // MARK: - State

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([ProductDesign])
        case failed(String)
    }

    // MARK: - Properties

    @Published private(set) var state: LoadState = .idle

    private let repository: ProductDesignRepository

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.repository = ProductDesignRepository(client: client)
    }

    // MARK: - Actions

    func load() async {
        state = .loading
        do {
            let designs = try await repository.fetchDesigns()
            state = .loaded(designs)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Make a definer view model that shares this list's repository.
    func makeDefinerViewModel() -> TemplateDefinerViewModel {
        TemplateDefinerViewModel(repository: repository)
    }
}
