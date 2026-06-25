// MARK: - TemplateDefinerViewModel
//
// Drives the spec-template definer form: holds the editable draft, exposes
// validation, and saves via the repository's atomic RPC. Holds no SwiftUI types.

import Foundation

@MainActor
final class TemplateDefinerViewModel: ObservableObject {

    // MARK: - Published state

    @Published var draft = DraftProductDesign()
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var didSave = false

    // MARK: - Dependencies

    private let repository: ProductDesignRepository

    // MARK: - Lifecycle

    init(repository: ProductDesignRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    /// The first blocking validation problem, or nil when the draft is saveable.
    var validationError: String? {
        draft.validationError
    }

    var canSave: Bool {
        !isSaving && draft.isValid
    }

    // MARK: - Attribute editing

    func addAttribute() {
        draft.attributes.append(DraftSpecAttribute())
    }

    func removeAttributes(at offsets: IndexSet) {
        draft.attributes.remove(atOffsets: offsets)
    }

    // MARK: - Save

    func save() async {
        guard canSave else {
            errorMessage = draft.validationError
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            try await repository.createDesign(from: draft)
            didSave = true
        } catch {
            errorMessage = Self.message(for: error)
        }

        isSaving = false
    }

    // MARK: - Private Helpers

    private static func message(for error: Error) -> String {
        let description = error.localizedDescription
        // A duplicate drawing_no/revision collides on the unique index; surface a
        // friendlier hint for that common case.
        if description.lowercased().contains("duplicate") || description.contains("23505") {
            return "A design with this drawing number and revision already exists."
        }
        return description.isEmpty ? "Could not save. Please try again." : description
    }
}
