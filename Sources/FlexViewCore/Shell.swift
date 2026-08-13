//
//  Shell.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var standardOutput: String
        public var standardError: String
        public var timedOut: Bool

        public var succeeded: Bool { exitCode == 0 && !timedOut }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case launchFailed(command: String, underlying: Swift.Error)
        case failed(command: String, result: Result)
        case timedOut(command: String, seconds: TimeInterval)

        public var description: String {
            switch self {
            case .launchFailed(let command, let underlying):
                "could not launch \(command): \(underlying)"
            case .failed(let command, let result):
                """
                \(command) exited with \(result.exitCode)
                \(result.standardError.isEmpty ? result.standardOutput : result.standardError)
                """
            case .timedOut(let command, let seconds):
                "\(command) did not finish within \(Int(seconds))s and was terminated."
            }
        }
    }

    /// Runs a command to completion, capturing both streams.
    ///
    /// - Parameter streamOutput: mirrors stdout/stderr to this process as it arrives,
    ///   for long builds where silence looks like a hang.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        streamOutput: Bool = false,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(streamOutput: streamOutput)
        outPipe.fileHandleForReading.readabilityHandler = { collector.appendOut($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }

        let description = ([executable] + arguments).joined(separator: " ")
        do {
            try process.run()
        } catch {
            throw Error.launchFailed(command: description, underlying: error)
        }
        let timedOut = wait(for: process, timeout: timeout)

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            timedOut: timedOut
        )
    }

    /// Returns true if the deadline passed and the process had to be killed.
    private static func wait(for process: Process, timeout: TimeInterval?) -> Bool {
        guard let timeout else {
            process.waitUntilExit()
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else {
            process.waitUntilExit()
            return false
        }

        // SIGTERM first so the runner can flush what it has, SIGKILL if it ignores us.
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return true
    }

    public static func runChecked(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        streamOutput: Bool = false,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        let result = try run(
            executable,
            arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            streamOutput: streamOutput,
            timeout: timeout
        )
        if result.timedOut, let timeout {
            throw Error.timedOut(command: ([executable] + arguments).joined(separator: " "), seconds: timeout)
        }
        guard result.succeeded else {
            throw Error.failed(command: ([executable] + arguments).joined(separator: " "), result: result)
        }
        return result
    }
}

/// Serializes appends from the two pipe reader queues.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private let streamOutput: Bool

    init(streamOutput: Bool) {
        self.streamOutput = streamOutput
    }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { out.append(data) }
        if streamOutput { FileHandle.standardOutput.write(data) }
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { err.append(data) }
        if streamOutput { FileHandle.standardError.write(data) }
    }

    var standardOutput: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var standardError: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
}
