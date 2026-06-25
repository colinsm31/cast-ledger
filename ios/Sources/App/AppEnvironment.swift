// MARK: - AppEnvironment
//
// App-wide dependency container. Owns the Supabase client (or the config error
// if setup is incomplete) and, when configured, the AuthService. Views read
// `setup` to choose between the setup-needed screen and the authenticated flow.

import Foundation
import Supabase

@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: - State

    enum SetupState {
        case ready(SupabaseClient, AuthService)
        case misconfigured(String)
    }

    // MARK: - Properties

    @Published private(set) var setup: SetupState

    // MARK: - Lifecycle

    init() {
        do {
            let client = try SupabaseClientProvider.makeClient()
            let authService = AuthService(client: client)
            self.setup = .ready(client, authService)
        } catch {
            self.setup = .misconfigured(error.localizedDescription)
        }
    }

    // MARK: - Accessors

    /// The configured client, or nil when setup is incomplete.
    var client: SupabaseClient? {
        guard case .ready(let client, _) = setup else {
            return nil
        }
        return client
    }

    /// The auth service, or nil when setup is incomplete.
    var authService: AuthService? {
        guard case .ready(_, let authService) = setup else {
            return nil
        }
        return authService
    }
}
