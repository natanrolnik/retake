//
//  main.swift
//  SampleApp
//
//  Created by Natan Rolnik on 13-08-2026.
//

import DesignSystem
import Feature
import FlexViewRuntime

// Referencing one type per module keeps the linker from stripping modules whose symbols
// are otherwise unused here; their previews are only reachable via runtime metadata.
_ = PrimaryButton.self
_ = CheckoutScreen.self

MacRunner.main()
