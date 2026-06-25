// MARK: - HomeViewModel
//
// Phase 0 smoke test: once signed in, read the seeded `categories` table. A
// successful fetch proves the end-to-end path — auth session → PostgREST → RLS
// allowing the authenticated role → JSONB/Codable decode. Replaced by real
// feature view-models in Phase 1.

import Foundation
import Supabase

@MainActor
final class HomeViewModel: ObservableObject {

    // MARK: - State

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([Category])
        case failed(String)
    }

    // MARK: - Properties

    @Published private(set) var state: LoadState = .idle

    private let client: SupabaseClient

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Actions

    /// Fetch the seeded categories as a connectivity + RLS smoke test.
    func loadCategories() async {
        state = .loading
        do {
            let categories: [Category] = try await client
                .from("categories")
                .select()
                .order("name")
                .execute()
                .value
            state = .loaded(categories)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
