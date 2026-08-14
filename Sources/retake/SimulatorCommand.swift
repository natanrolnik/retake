//
//  SimulatorCommand.swift
//  retake
//
//  Created by Natan Rolnik on 14-08-2026.
//

import ArgumentParser

/// Prints the simulator retake would render on.
///
/// Exists so a caller can boot the same one ahead of time. Booting is the largest single
/// cost in a CI run, and booting a different simulator than the render uses buys nothing.
struct SimulatorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simulator",
        abstract: "Print the simulator retake would use when none is named."
    )

    @Flag(name: .long, help: "Print only the device name, without the runtime version.")
    var nameOnly: Bool = false

    func run() async throws {
        let device = try SimulatorPicker.pick()
        print(nameOnly ? device.name : device.descriptor)
    }
}
