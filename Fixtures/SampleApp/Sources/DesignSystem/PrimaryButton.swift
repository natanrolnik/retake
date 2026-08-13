//
//  PrimaryButton.swift
//  SampleApp
//
//  Created by Natan Rolnik on 13-08-2026.
//

import SwiftUI

public struct PrimaryButton: View {
    private let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview("Primary button") {
    PrimaryButton(title: "Continue")
}

#Preview("Primary button, long title") {
    PrimaryButton(title: "Continue to the next step")
}
