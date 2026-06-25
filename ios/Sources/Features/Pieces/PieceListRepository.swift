// MARK: - PieceListRepository
//
// Reads pieces (with their embedded design summary) for the list and detail
// views. One query fetches both via PostgREST resource embedding.

import Foundation
import Supabase

struct PieceListRepository {

    // MARK: - Constants

    private enum Query {
        // pieces.* plus the embedded design's display fields.
        static let select = """
        *, product_designs(family, name, drawing_no, revision)
        """
    }

    // MARK: - Properties

    private let client: SupabaseClient

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Reads

    /// All pieces, newest first, with their design summary embedded.
    func fetchPieces() async throws -> [PieceListItem] {
        try await client
            .from("pieces")
            .select(Query.select)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// A single piece with its design summary.
    func fetchPiece(id: UUID) async throws -> PieceListItem {
        try await client
            .from("pieces")
            .select(Query.select)
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }
}
