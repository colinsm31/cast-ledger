// MARK: - Lookups
//
// Reusable add-if-missing vocabularies (units, field names, enum values) so the
// editors let engineers pick instead of retype. Backed by the lookup_values
// table and the add_lookup_value RPC (insert-if-missing, see 0005).

import Foundation
import Supabase

// MARK: - LookupKind

/// The vocabulary a lookup value belongs to. Raw values match the `kind` column.
enum LookupKind: String {
    case unit
    case fieldName = "field_name"
    case enumValue = "enum_value"
}

// MARK: - LookupValue

struct LookupValue: Codable, Identifiable, Hashable {
    let id: UUID
    var kind: String
    var value: String
    var createdAt: Date
}

// MARK: - LookupRepository

struct LookupRepository {

    // MARK: - Properties

    private let client: SupabaseClient

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Reads

    /// All values for a kind, alphabetised.
    func fetchValues(kind: LookupKind) async throws -> [String] {
        let rows: [LookupValue] = try await client
            .from("lookup_values")
            .select()
            .eq("kind", value: kind.rawValue)
            .order("value")
            .execute()
            .value
        return rows.map(\.value)
    }

    // MARK: - Writes

    /// Add a value if missing; returns the trimmed canonical value.
    @discardableResult
    func addValue(kind: LookupKind, value: String) async throws -> String {
        struct Params: Encodable {
            let pKind: String
            let pValue: String
        }
        return try await client
            .rpc("add_lookup_value", params: Params(pKind: kind.rawValue, pValue: value))
            .single()
            .execute()
            .value
    }
}
