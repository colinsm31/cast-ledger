// MARK: - PieceStatusBadge
//
// Reusable colored badge for a piece's lifecycle status. One place for the
// status → label/color mapping so the list, detail, and future screens agree.

import SwiftUI

struct PieceStatusBadge: View {

    let status: PieceStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

// MARK: - PieceStatus presentation

extension PieceStatus {

    var displayName: String {
        switch self {
        case .inProduction: return "In production"
        case .curing:       return "Curing"
        case .qc:           return "QC"
        case .ready:        return "Ready"
        case .staged:       return "Staged"
        case .delivered:    return "Delivered"
        case .unknown:      return "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .inProduction: return .orange
        case .curing:       return .yellow
        case .qc:           return .purple
        case .ready:        return .green
        case .staged:       return .blue
        case .delivered:    return .gray
        case .unknown:      return Color.gray
        }
    }
}
