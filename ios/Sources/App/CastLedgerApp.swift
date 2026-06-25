// MARK: - CastLedgerApp
//
// App entry point. Builds the shared Supabase client once and injects an
// AppEnvironment into the SwiftUI environment for views/view-models to use.

import SwiftUI

@main
struct CastLedgerApp: App {

    // MARK: - Properties

    @StateObject private var environment = AppEnvironment()

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}
