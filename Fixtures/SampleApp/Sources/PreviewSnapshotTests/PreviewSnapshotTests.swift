//
//  PreviewSnapshotTests.swift
//  SampleApp
//
//  Created by Natan Rolnik on 13-08-2026.
//

import DesignSystem
import Feature
import FlexViewTestRuntime

// Referencing one type per module keeps the linker from stripping modules whose symbols
// are otherwise unused here; their previews are only reachable through runtime metadata.
private let linked: [Any.Type] = [PrimaryButton.self, CheckoutScreen.self]

final class PreviewSnapshotTests: FlexViewSnapshotTests {}
