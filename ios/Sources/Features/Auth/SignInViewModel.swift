// MARK: - SignInViewModel
//
// Drives the sign-in form: input, validation, loading, and error state. Talks to
// AuthService; holds no UIKit/SwiftUI types so it stays unit-testable.

import Foundation

@MainActor
final class SignInViewModel: ObservableObject {

    // MARK: - Published state

    @Published var email: String = ""
    @Published var password: String = ""
    @Published private(set) var isSubmitting: Bool = false
    @Published private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let authService: AuthService

    // MARK: - Lifecycle

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Validation

    /// True when the form has enough to attempt a sign-in.
    var canSubmit: Bool {
        guard !isSubmitting else {
            return false
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedEmail.contains("@") && !password.isEmpty
    }

    // MARK: - Actions

    func signIn() async {
        guard canSubmit else {
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            try await authService.signIn(email: email, password: password)
            // On success, AuthService flips app state; this view is replaced.
        } catch {
            errorMessage = Self.message(for: error)
        }

        isSubmitting = false
    }

    // MARK: - Private Helpers

    private static func message(for error: Error) -> String {
        // Supabase returns a descriptive message for bad credentials; fall back
        // to a generic line for anything unexpected.
        let description = error.localizedDescription
        if description.isEmpty {
            return "Could not sign in. Please try again."
        }
        return description
    }
}
