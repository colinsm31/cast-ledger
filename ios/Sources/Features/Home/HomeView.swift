// MARK: - HomeView
//
// Phase 0 signed-in shell. Confirms the authenticated session and runs the
// categories smoke test (proves auth → PostgREST → RLS → decode works end to
// end). Offers sign-out. Feature screens attach to this navigation stack next.

import SwiftUI
import Supabase

struct HomeView: View {

    // MARK: - Properties

    @ObservedObject var authService: AuthService
    @StateObject private var viewModel: HomeViewModel
    let client: SupabaseClient
    let user: User

    @State private var isSigningOut = false

    // MARK: - Lifecycle

    init(authService: AuthService, client: SupabaseClient, user: User) {
        self.authService = authService
        self.client = client
        self.user = user
        _viewModel = StateObject(wrappedValue: HomeViewModel(client: client))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                featuresSection
                accountSection
                smokeTestSection
            }
            .navigationTitle("CastLedger")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out", role: .destructive) {
                        signOut()
                    }
                    .disabled(isSigningOut)
                }
            }
            .task {
                await viewModel.loadCategories()
            }
        }
    }

    // MARK: - Subviews

    private var featuresSection: some View {
        Section("Build") {
            NavigationLink {
                TemplateListView(client: client)
            } label: {
                Label("Product families", systemImage: "square.stack.3d.up")
            }
            NavigationLink {
                PieceFamilyPickerView(client: client)
            } label: {
                Label("New piece", systemImage: "shippingbox")
            }
            NavigationLink {
                PiecesListView(client: client)
            } label: {
                Label("Pieces", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private var accountSection: some View {
        Section("Signed in") {
            Label(user.email ?? user.id.uuidString, systemImage: "person.crop.circle")
        }
    }

    @ViewBuilder
    private var smokeTestSection: some View {
        Section("Backend check — categories") {
            switch viewModel.state {
            case .idle, .loading:
                HStack {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary)
                }
            case .loaded(let categories):
                if categories.isEmpty {
                    Text("Connected, but no rows returned. Did the seed run, and does RLS allow this user?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(categories) { category in
                        Label(category.name, systemImage: "shippingbox")
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Private Helpers

    private func signOut() {
        isSigningOut = true
        Task {
            try? await authService.signOut()
            isSigningOut = false
        }
    }
}
