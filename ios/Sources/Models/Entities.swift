// MARK: - Entity models
//
// Codable mirrors of the Phase 0 Postgres tables. Snake_case ↔ camelCase is
// handled globally by the decoder/encoder key strategy configured on the
// Supabase client (see SupabaseClientProvider), so these models declare plain
// camelCase properties without per-field CodingKeys.
//
// JSONB columns map to JSONValue (object/array). Strongly-typed relational
// fields stay strongly typed. Append-only tables (InventoryTxn, QCTest) have no
// update path in the app — they are inserted, never mutated.

import Foundation

// MARK: - Project

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var jobNumber: String
    var name: String
    var client: String?
    var location: String?
    var status: ProjectStatus
    var isStock: Bool
    var createdAt: Date
}

// MARK: - ProductDesign (template)

struct ProductDesign: Codable, Identifiable, Hashable {
    let id: UUID
    var drawingNo: String
    var family: String
    var name: String
    var baseSpecs: JSONValue
    var specTemplate: JSONValue
    var defaultComponents: JSONValue
    var revision: Int
    var supersededById: UUID?
    var createdAt: Date
}

// MARK: - MixDesign

struct MixDesign: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var targetPsi: Int?
    var slumpIn: Double?
    var recipe: JSONValue
    var createdAt: Date
}

// MARK: - Category

struct Category: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
}

// MARK: - SpecAttribute (one field definition within a template)

struct SpecAttribute: Codable, Identifiable, Hashable {
    let id: UUID
    var ownerType: SpecAttributeOwnerType
    var ownerId: UUID
    var name: String
    var valueType: SpecValueType
    var unit: String?
    var required: Bool
    var qcGate: Bool
    var validMin: Double?
    var validMax: Double?
    var enumValues: JSONValue?
    var createdAt: Date
}

// MARK: - Material

struct Material: Codable, Identifiable, Hashable {
    let id: UUID
    var categoryId: UUID
    var description: String
    var defaultUom: String
    var defaultCost: Double?
    var specValues: JSONValue
    var createdAt: Date
}

// MARK: - CastingForm (mold)
//
// Named CastingForm, not Form, to avoid shadowing SwiftUI's `Form` view. Maps to
// the `forms` table.

struct CastingForm: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var productDesignId: UUID?
    var location: String?
    var condition: FormCondition
    var useCount: Int
    var currentCastRunId: UUID?
    var createdAt: Date
}

// MARK: - CastRun (a pour; snapshots the design revision actually poured)

struct CastRun: Codable, Identifiable, Hashable {
    let id: UUID
    var castDate: Date
    var productDesignId: UUID
    var productDesignRevision: Int
    var mixDesignId: UUID?
    var formId: UUID?
    var batchNo: String
    var qty: Int
    var laborHours: Double?
    var createdAt: Date
}

// MARK: - Piece (serialized instance — the heart; never a SKU)

struct Piece: Codable, Identifiable, Hashable {
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
}

// MARK: - QCTest (APPEND ONLY — bound to the piece/batch revision poured)

struct QCTest: Codable, Identifiable, Hashable {
    let id: UUID
    var pieceId: UUID?
    var batchNo: String?
    var testType: QCTestType
    var value: Double?
    var unit: String?
    var pass: Bool?
    var testedAt: Date
    var testedBy: String?
}

// MARK: - InventoryTxn (APPEND ONLY ledger — balances are derived, never stored)

struct InventoryTxn: Codable, Identifiable, Hashable {
    let id: UUID
    var txnType: InventoryTxnType
    var materialId: UUID
    var qty: Double
    var unitCost: Double?
    var fromLocation: String?
    var toLocation: String?
    var castRunId: UUID?
    var projectId: UUID?
    var userId: UUID?
    var createdAt: Date
}
