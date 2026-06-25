// MARK: - SignInView
//
// Email/password sign-in. Shown when the app is signed out. On success the app
// shell swaps to the authenticated experience (driven by AuthService state).

import SwiftUI

struct SignInView: View {

    // MARK: - Properties

    @StateObject private var viewModel: SignInViewModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    // MARK: - Lifecycle

    init(authService: AuthService) {
        _viewModel = StateObject(wrappedValue: SignInViewModel(authService: authService))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            header
            form
            errorText
            signInButton
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("CastLedger")
                .font(.largeTitle.bold())
            Text("Sign in to continue")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 48)
    }

    private var form: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $viewModel.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await viewModel.signIn() } }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let message = viewModel.errorMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        }
    }

    private var signInButton: some View {
        Button {
            focusedField = nil
            Task { await viewModel.signIn() }
        } label: {
            HStack {
                if viewModel.isSubmitting {
                    ProgressView()
                        .tint(.white)
                }
                Text(viewModel.isSubmitting ? "Signing in…" : "Sign in")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canSubmit)
    }
}
