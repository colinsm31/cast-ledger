// MARK: - LookupStore
//
// Observable cache of lookup values per kind, shared by the editor's pick-or-add
// controls. Loads each kind once on demand; when the user adds a new value it's
// persisted via the RPC and appended to the in-memory list so every control
// using that kind sees it immediately.

import Foundation
import Supabase

@MainActor
final class LookupStore: ObservableObject {

    // MARK: - Properties

    /// Cached values keyed by kind raw value. Sorted, de-duplicated.
    @Published private(set) var valuesByKind: [String: [String]] = [:]

    private let repository: LookupRepository
    private var loadingKinds: Set<String> = []

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.repository = LookupRepository(client: client)
    }

    // MARK: - Accessors

    /// Current cached values for a kind (empty until loaded).
    func values(for kind: LookupKind) -> [String] {
        valuesByKind[kind.rawValue] ?? []
    }

    // MARK: - Loading

    /// Load a kind's values once. No-op if already loaded or loading.
    func loadIfNeeded(_ kind: LookupKind) async {
        let key = kind.rawValue
        guard valuesByKind[key] == nil, !loadingKinds.contains(key) else {
            return
        }
        loadingKinds.insert(key)
        defer { loadingKinds.remove(key) }

        do {
            let values = try await repository.fetchValues(kind: kind)
            valuesByKind[key] = values
        } catch {
            // Leave unloaded so a later open can retry; the control still works
            // as free text in the meantime.
            valuesByKind[key] = valuesByKind[key] ?? []
        }
    }

    // MARK: - Adding

    /// Persist a new value (if missing) and merge it into the cache. Returns the
    /// canonical trimmed value, or the trimmed input if the save failed (so the
    /// editor can still use what the user typed).
    @discardableResult
    func add(_ rawValue: String, to kind: LookupKind) async -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let canonical: String
        do {
            canonical = try await repository.addValue(kind: kind, value: trimmed)
        } catch {
            return trimmed
        }

        merge(canonical, into: kind.rawValue)
        return canonical
    }

    // MARK: - Private Helpers

    private func merge(_ value: String, into key: String) {
        var values = valuesByKind[key] ?? []
        guard !values.contains(value) else {
            return
        }
        values.append(value)
        values.sort()
        valuesByKind[key] = values
    }
}
