// MARK: - RootView
//
// Top-level routing. Three layers:
//   1. Config — if Supabase isn't configured, show ConfigurationNeededView.
//   2. Auth   — otherwise observe AuthService: loading → sign-in → signed-in.
//   3. Shell  — the signed-in placeholder home (feature screens attach here next).

import SwiftUI
import Supabase   // SupabaseClient, User

struct RootView: View {

    // MARK: - Properties

    @EnvironmentObject private var environment: AppEnvironment

    // MARK: - Body

    var body: some View {
        switch environment.setup {
        case .misconfigured(let message):
            ConfigurationNeededView(message: message)
        case .ready(let client, let authService):
            AuthenticatedRouter(client: client, authService: authService)
        }
    }
}

// MARK: - AuthenticatedRouter

/// Observes auth state and routes between loading, sign-in, and the home shell.
private struct AuthenticatedRouter: View {

    let client: SupabaseClient
    @ObservedObject var authService: AuthService

    var body: some View {
        switch authService.state {
        case .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            SignInView(authService: authService)
        case .signedIn(let user):
            HomeView(authService: authService, client: client, user: user)
        }
    }
}

// MARK: - ConfigurationNeededView

/// Shown when Supabase config is missing — guides the developer to fix setup
/// rather than crashing.
struct ConfigurationNeededView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Setup needed")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
