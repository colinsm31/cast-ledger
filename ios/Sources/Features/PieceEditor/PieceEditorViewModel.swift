// MARK: - PieceEditorViewModel
//
// Drives the piece clone-and-edit editor for one chosen design. Loads the
// template's spec attributes into editable fields, holds the universal piece
// fields, validates everything in-app against the template, assembles the
// spec_values JSONB, and saves via the repository's create_piece RPC.

import Foundation
import Supabase

@MainActor
final class PieceEditorViewModel: ObservableObject {

    // MARK: - Load state for the template

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Published state

    @Published private(set) var loadState: LoadState = .loading

    // Universal piece fields.
    @Published var markNo = ""
    @Published var selectedProjectID: UUID?
    @Published var yardLocation = ""
    @Published var weightInput = ""

    // Template-driven spec fields.
    @Published var specFields: [PieceSpecField] = []

    // Projects for the picker.
    @Published private(set) var projects: [Project] = []

    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var didSave = false

    // MARK: - Dependencies

    let design: ProductDesign
    private let repository: PieceRepository

    // MARK: - Lifecycle

    init(design: ProductDesign, client: SupabaseClient) {
        self.design = design
        self.repository = PieceRepository(client: client)
    }

    // MARK: - Loading

    func load() async {
        loadState = .loading
        do {
            async let attributes = repository.fetchAttributes(for: design.id)
            async let projectList = repository.fetchProjects()
            let (loadedAttributes, loadedProjects) = try await (attributes, projectList)

            specFields = loadedAttributes.map(PieceSpecField.init)
            projects = loadedProjects
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Validation

    /// The first blocking validation problem, or nil when saveable.
    var validationError: String? {
        if markNo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Mark number is required"
        }
        if !weightInput.isEmpty, Double(weightInput) == nil {
            return "Weight must be a number"
        }
        if let firstFieldError = specFields.compactMap(\.validationError).first {
            return firstFieldError
        }
        return nil
    }

    var canSave: Bool {
        loadState == .ready && !isSaving && validationError == nil
    }

    // MARK: - Save

    func save() async {
        guard canSave else {
            errorMessage = validationError
            return
        }

        isSaving = true
        errorMessage = nil

        // Assemble spec_values JSONB from the non-empty fields.
        var values: [String: JSONValue] = [:]
        for field in specFields {
            if let jsonValue = field.jsonValue {
                values[field.name] = jsonValue
            }
        }

        do {
            try await repository.createPiece(
                markNo: markNo.trimmingCharacters(in: .whitespacesAndNewlines),
                designID: design.id,
                projectID: selectedProjectID,
                specValues: .object(values),
                weightLb: Double(weightInput),
                yardLocation: yardLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            didSave = true
        } catch {
            errorMessage = Self.message(for: error)
        }

        isSaving = false
    }

    // MARK: - Private Helpers

    private static func message(for error: Error) -> String {
        let description = error.localizedDescription
        if description.lowercased().contains("duplicate") || description.contains("23505") {
            return "A piece with this mark number already exists."
        }
        return description.isEmpty ? "Could not save. Please try again." : description
    }
}
