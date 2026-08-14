//
//  main.swift
//  SampleMac
//
//  Created by Natan Rolnik on 14-08-2026.
//

import RetakeRuntime
import MacDesignSystem

// Referencing one type per module keeps the linker from stripping modules whose symbols
// are otherwise unused here; their previews are only reachable through runtime metadata.
private let linked: [Any.Type] = [StatusPill.self]

MacRunner.main()
