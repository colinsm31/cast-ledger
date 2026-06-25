// MARK: - Insert payloads
//
// Encodable payloads for creating rows where the server fills in id/created_at
// defaults. IDs are client-generatable UUIDs (the schema allows it and it keeps
// the door open for offline later), so we send id explicitly to make inserts
// idempotent and to know the new row's id without a round-trip.
//
// The append-only ledgers (qc_tests, inventory_txns) are insert-only by design —
// these are the only writes the app makes against them.

import Foundation

// MARK: - New QC test (append-only)

struct NewQCTest: Encodable {
    var id: UUID = UUID()
    var pieceId: UUID?
    var batchNo: String?
    var testType: QCTestType
    var value: Double?
    var unit: String?
    var pass: Bool?
    var testedBy: String?
}

// MARK: - New inventory transaction (append-only)

struct NewInventoryTxn: Encodable {
    var id: UUID = UUID()
    var txnType: InventoryTxnType
    var materialId: UUID
    var qty: Double
    var unitCost: Double?
    var fromLocation: String?
    var toLocation: String?
    var castRunId: UUID?
    var projectId: UUID?
    var userId: UUID?
}

// MARK: - New piece

struct NewPiece: Encodable {
    var id: UUID = UUID()
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
}
