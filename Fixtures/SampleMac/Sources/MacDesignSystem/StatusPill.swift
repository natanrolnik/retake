//
//  StatusPill.swift
//  SampleMac
//
//  Created by Natan Rolnik on 14-08-2026.
//

import SwiftUI

public struct StatusPill: View {
    public enum Status: String, CaseIterable {
        case idle = "Idle"
        case running = "Running"
        case failed = "Failed"

        var color: Color {
            switch self {
            case .idle: .gray
            case .running: .blue
            case .failed: .red
            }
        }
    }

    private let status: Status

    public init(status: Status) {
        self.status = status
    }

    public var body: some View {
        Text(status.rawValue)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(status.color, in: Capsule())
    }
}

#Preview("Every status") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(StatusPill.Status.allCases, id: \.self) { status in
            StatusPill(status: status)
        }
    }
    .padding()
}

#Preview("Running") {
    StatusPill(status: .running)
        .padding()
}
