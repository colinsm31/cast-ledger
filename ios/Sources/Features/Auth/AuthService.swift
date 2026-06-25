// MARK: - AuthService
//
// Wraps the Supabase Auth client for email/password sign-in. Owns the observed
// auth state for the app and exposes simple async methods for the view models.
//
// Sessions are persisted by the Supabase SDK in the iOS Keychain (its default
// local storage) — credentials are never written to UserDefaults or plain files
// (secure-credential-storage). On launch we restore the stored session and then
// listen for auth-state changes for the lifetime of the app.

import Foundation
import Supabase

@MainActor
final class AuthService: ObservableObject {

    // MARK: - Auth state

    enum AuthState: Equatable {
        case loading          // restoring a stored session at launch
        case signedOut
        case signedIn(User)
    }

    // MARK: - Properties

    @Published private(set) var state: AuthState = .loading

    private let client: SupabaseClient
    private var observationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init(client: SupabaseClient) {
        self.client = client
        startObservingAuthState()
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Actions

    /// Sign in with email and password. Throws on invalid credentials / network error.
    func signIn(email: String, password: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await client.auth.signIn(email: trimmedEmail, password: password)
        // State updates via the authStateChanges stream (.signedIn).
    }

    /// Sign out the current user and clear the stored session.
    func signOut() async throws {
        try await client.auth.signOut()
        // State updates via the authStateChanges stream (.signedOut).
    }

    // MARK: - Private Helpers

    /// Listen to auth-state changes for the app's lifetime. The stream emits an
    /// initial event reflecting any restored session, so this also drives the
    /// launch transition out of `.loading`.
    private func startObservingAuthState() {
        observationTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await (event, session) in self.client.auth.authStateChanges {
                await self.handle(event: event, session: session)
            }
        }
    }

    private func handle(event: AuthChangeEvent, session: Session?) {
        switch event {
        case .initialSession:
            // With emitLocalSessionAsInitialSession the restored session is emitted
            // as-is, so treat an expired one as signed-out (the SDK will refresh and
            // re-emit .signedIn / .tokenRefreshed if the refresh token is still good).
            if let session, !session.isExpired {
                state = .signedIn(session.user)
            } else {
                state = .signedOut
            }
        case .signedIn, .tokenRefreshed, .userUpdated:
            if let user = session?.user {
                state = .signedIn(user)
            }
        case .signedOut:
            state = .signedOut
        default:
            break
        }
    }
}
