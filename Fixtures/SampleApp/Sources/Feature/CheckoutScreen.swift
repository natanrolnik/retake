//
//  CheckoutScreen.swift
//  SampleApp
//
//  Created by Natan Rolnik on 13-08-2026.
//

import DesignSystem
import SwiftUI

/// Consumes DesignSystem without owning any of its files. A change to PrimaryButton
/// must show up here too, which is the downstream case file-to-target ownership misses.
public struct CheckoutScreen: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Cart").font(.title2)
                Badge(count: 3)
            }
            PrimaryButton(title: "Continue")
        }
        .padding(24)
    }
}

#Preview("Checkout") {
    CheckoutScreen()
}
