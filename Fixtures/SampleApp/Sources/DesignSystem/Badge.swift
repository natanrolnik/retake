//
//  Badge.swift
//  SampleApp
//
//  Created by Natan Rolnik on 13-08-2026.
//

import SwiftUI

public struct Badge: View {
    private let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Text("\(count)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(6)
            .background(Color.red, in: Circle())
    }
}

// Unnamed on purpose: exercises the ordinal fallback in PreviewID.
#Preview {
    Badge(count: 3)
}
