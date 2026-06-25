// MARK: - EmptyStateView
//
// iOS 16-compatible empty/error state (ContentUnavailableView is iOS 17+).
// Centered icon, title, optional message, and an optional action button.

import SwiftUI

struct EmptyStateView: View {

    // MARK: - Properties

    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
