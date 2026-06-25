// MARK: - PieceRepository
//
// Data access for the piece clone-and-edit editor: load a design's spec
// attributes (to drive the form), load projects (for assignment), and create a
// piece atomically via the create_piece RPC (see 0006).

import Foundation
import Supabase

struct PieceRepository {

    // MARK: - Properties

    private let client: SupabaseClient

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Reads

    /// All product designs (families) to clone from, newest first.
    func fetchDesigns() async throws -> [ProductDesign] {
        try await client
            .from("product_designs")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// The spec-attribute definitions for a design, in stable order.
    func fetchAttributes(for designID: UUID) async throws -> [SpecAttribute] {
        try await client
            .from("spec_attributes")
            .select()
            .eq("owner_type", value: SpecAttributeOwnerType.productDesign.rawValue)
            .eq("owner_id", value: designID.uuidString)
            .order("created_at")
            .execute()
            .value
    }

    /// Projects available to commit a piece to.
    func fetchProjects() async throws -> [Project] {
        try await client
            .from("projects")
            .select()
            .order("job_number")
            .execute()
            .value
    }

    // MARK: - Writes

    /// Create a piece atomically; returns the new piece id.
    @discardableResult
    func createPiece(
        markNo: String,
        designID: UUID,
        projectID: UUID?,
        specValues: JSONValue,
        weightLb: Double?,
        yardLocation: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let pMarkNo: String
            let pProductDesignId: UUID
            let pProjectId: UUID?
            let pSpecValues: JSONValue
            let pWeightLb: Double?
            let pYardLocation: String?
        }

        let params = Params(
            pMarkNo: markNo,
            pProductDesignId: designID,
            pProjectId: projectID,
            pSpecValues: specValues,
            pWeightLb: weightLb,
            pYardLocation: yardLocation
        )

        return try await client
            .rpc("create_piece", params: params)
            .single()
            .execute()
            .value
    }
}
