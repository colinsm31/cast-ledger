// MARK: - Domain enums
//
// Closed-set columns from the schema, mirrored as Swift enums. These match the
// CHECK constraints in 0001_core_schema.sql. Decoding is lenient at the edge
// (unknown raw values map to `.unknown`) so a new server value never crashes an
// older client — parse-don't-trust.

import Foundation

// MARK: - Piece lifecycle

/// `pieces.status` — in_production → curing → qc → ready → staged → delivered.
enum PieceStatus: String, Codable, CaseIterable, Hashable {
    case inProduction = "in_production"
    case curing
    case qc
    case ready
    case staged
    case delivered
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PieceStatus(rawValue: raw) ?? .unknown
    }

    /// The next status in the standard lifecycle, if any.
    var next: PieceStatus? {
        switch self {
        case .inProduction: return .curing
        case .curing:       return .qc
        case .qc:           return .ready
        case .ready:        return .staged
        case .staged:       return .delivered
        case .delivered, .unknown: return nil
        }
    }
}

// MARK: - Inventory ledger

/// `inventory_txns.txn_type` — the append-only material ledger movements.
enum InventoryTxnType: String, Codable, CaseIterable, Hashable {
    case receipt
    case issueToCastRun = "issue_to_cast_run"
    case transfer
    case adjust
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InventoryTxnType(rawValue: raw) ?? .unknown
    }
}

// MARK: - QC

/// `qc_tests.test_type`.
enum QCTestType: String, Codable, CaseIterable, Hashable {
    case break7day = "break_7day"
    case break28day = "break_28day"
    case waterTest = "water_test"
    case other
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QCTestType(rawValue: raw) ?? .unknown
    }
}

// MARK: - Projects

/// `projects.status`.
enum ProjectStatus: String, Codable, CaseIterable, Hashable {
    case active
    case closed
    case onHold = "on_hold"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProjectStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - Forms

/// `forms.condition`.
enum FormCondition: String, Codable, CaseIterable, Hashable {
    case good
    case worn
    case needsRepair = "needs_repair"
    case retired
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FormCondition(rawValue: raw) ?? .unknown
    }
}

// MARK: - Spec attributes

/// `spec_attributes.value_type` — the declared type of a template field.
enum SpecValueType: String, Codable, CaseIterable, Hashable {
    case number
    case text
    case enumeration = "enum"
    case bool
    case ref
    case list
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpecValueType(rawValue: raw) ?? .unknown
    }
}

/// `spec_attributes.owner_type`.
enum SpecAttributeOwnerType: String, Codable, CaseIterable, Hashable {
    case category
    case productDesign = "product_design"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpecAttributeOwnerType(rawValue: raw) ?? .unknown
    }
}
