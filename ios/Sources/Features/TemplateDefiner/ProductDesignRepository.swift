// MARK: - ProductDesignRepository
//
// Data access for the spec-template definer. Reads existing product designs and
// creates a new design + its attributes atomically via the create_product_design
// RPC (one transaction server-side — see 0004 migration). Keeps PostgREST details
// out of the view model.

import Foundation
import Supabase

// MARK: - RPC payload

/// One attribute as the create_product_design function expects it. Encoded with
/// the client's snake_case strategy → keys match the function's jsonb shape.
private struct AttributePayload: Encodable {
    let name: String
    let valueType: String
    let unit: String?
    let required: Bool
    let qcGate: Bool
    let validMin: String?
    let validMax: String?
    let enumValues: [String]?
}

/// The full argument set for the RPC call.
private struct CreateDesignParams: Encodable {
    let pDrawingNo: String
    let pFamily: String
    let pName: String
    let pRevision: Int
    let pAttributes: [AttributePayload]
}

// MARK: - Repository

struct ProductDesignRepository {

    // MARK: - Properties

    private let client: SupabaseClient

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Reads

    /// All product designs, newest first.
    func fetchDesigns() async throws -> [ProductDesign] {
        try await client
            .from("product_designs")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Writes

    /// Create a design and its attributes atomically. Returns the new design id.
    @discardableResult
    func createDesign(from draft: DraftProductDesign) async throws -> UUID {
        let attributes = draft.attributes.map { attribute -> AttributePayload in
            let trimmedUnit = attribute.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            return AttributePayload(
                name: attribute.name.trimmingCharacters(in: .whitespacesAndNewlines),
                valueType: attribute.valueType.rawValue,
                unit: trimmedUnit.isEmpty ? nil : trimmedUnit,
                required: attribute.required,
                qcGate: attribute.qcGate,
                validMin: attribute.validMin.isEmpty ? nil : attribute.validMin,
                validMax: attribute.validMax.isEmpty ? nil : attribute.validMax,
                enumValues: attribute.valueType == .enumeration ? attribute.parsedEnumValues : nil
            )
        }

        let params = CreateDesignParams(
            pDrawingNo: draft.drawingNo.trimmingCharacters(in: .whitespacesAndNewlines),
            pFamily: draft.family.trimmingCharacters(in: .whitespacesAndNewlines),
            pName: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            pRevision: draft.revision,
            pAttributes: attributes
        )

        return try await client
            .rpc("create_product_design", params: params)
            .single()
            .execute()
            .value
    }
}
