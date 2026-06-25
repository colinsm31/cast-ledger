// MARK: - PieceListItem
//
// A piece row joined with its design's display fields, fetched in one query via
// PostgREST resource embedding (pieces.product_design_id → product_designs).
// The embedded many-to-one resource decodes as a single nested object under the
// `product_designs` key (→ `productDesigns` with the snake_case strategy).

import Foundation

struct PieceListItem: Codable, Identifiable, Hashable {

    // MARK: - Embedded design summary

    struct DesignSummary: Codable, Hashable {
        var family: String
        var name: String
        var drawingNo: String
        var revision: Int
    }

    // MARK: - Piece fields

    let id: UUID
    var markNo: String
    var projectId: UUID?
    var productDesignId: UUID
    var productDesignRevision: Int
    var castRunId: UUID?
    var specValues: JSONValue
    var asBuiltComponents: JSONValue
    var weightLb: Double?
    var status: PieceStatus
    var yardLocation: String?
    var createdAt: Date
    var updatedAt: Date

    // The embedded design (nil if the join returned nothing, defensively).
    var productDesigns: DesignSummary?

    // MARK: - Convenience

    var familyName: String {
        productDesigns?.family ?? "—"
    }

    var designName: String {
        productDesigns?.name ?? "—"
    }
}
