//
//  SimulatorPicker.swift
//  retake
//
//  Created by Natan Rolnik on 14-08-2026.
//

import Foundation

/// Chooses a simulator when the caller did not name one.
///
/// A hardcoded default ages badly: "iPhone 16" is not installed on a machine with Xcode
/// 26, and the failure arrives minutes into a build. Asking the machine what it has costs
/// a few milliseconds and always names something real.
///
/// The choice is printed wherever it is used, because a render is only comparable to
/// another render on the same device: silently picking a different simulator between the
/// base and head passes would make every preview look changed.
enum SimulatorPicker {
    struct Device {
        var name: String
        var runtime: String
        var isBooted: Bool
        /// What simctl needs; a name is ambiguous across runtimes.
        var udid: String

        /// What `--simulator` accepts, and what a caller can pin.
        var descriptor: String { "\(name),\(runtime)" }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case noneAvailable

        var description: String {
            """
            No available iOS simulator was found. Install one in Xcode, or name it with \
            --simulator "iPhone 17,26.0".
            """
        }
    }

    /// Finds the device a descriptor names, so a caller who pinned one can still be
    /// matched to a udid.
    static func find(descriptor: String) throws -> Device? {
        let parts = descriptor.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let name = parts.first ?? descriptor
        let runtime = parts.count > 1 ? parts[1] : nil
        let devices = try all()
        return devices.first { $0.name == name && (runtime == nil || $0.runtime == runtime) }
    }

    private static func all() throws -> [Device] {
        let result = try Shell.runChecked(
            "/usr/bin/xcrun",
            ["simctl", "list", "devices", "available", "--json"]
        )
        return try parse(result.standardOutput)
    }

    /// - Returns: a booted simulator if there is one, otherwise the newest iPhone.
    static func pick() throws -> Device {
        let devices = try all()
        guard !devices.isEmpty else { throw Error.noneAvailable }

        // A booted device saves the minutes a cold boot costs, and is almost always the
        // one the caller has been using.
        if let booted = devices.first(where: \.isBooted) { return booted }
        return devices[0]
    }

    /// Exposed for testing: the JSON shape is simctl's, not ours.
    static func parse(_ json: String) throws -> [Device] {
        guard
            let data = json.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let byRuntime = root["devices"] as? [String: Any]
        else {
            return []
        }

        var devices: [Device] = []
        for (runtimeID, entries) in byRuntime {
            // "com.apple.CoreSimulator.SimRuntime.iOS-26-0" -> "26.0"
            guard let range = runtimeID.range(of: "SimRuntime.iOS-") else { continue }
            let runtime = runtimeID[range.upperBound...].replacingOccurrences(of: "-", with: ".")

            for entry in (entries as? [[String: Any]]) ?? [] {
                guard
                    let name = entry["name"] as? String,
                    (entry["isAvailable"] as? Bool) ?? false,
                    name.hasPrefix("iPhone")
                else {
                    continue
                }
                devices.append(Device(
                    name: name,
                    runtime: runtime,
                    isBooted: (entry["state"] as? String) == "Booted",
                    udid: (entry["udid"] as? String) ?? ""
                ))
            }
        }

        // Newest runtime first, then the higher numbered iPhone, so the default tracks
        // the machine's newest device rather than whatever simctl happens to list first.
        return devices.sorted { (lhs: Device, rhs: Device) -> Bool in
            if lhs.runtime != rhs.runtime {
                return isDescending(version(lhs.runtime), version(rhs.runtime))
            }
            return isDescending(modelOrder(lhs.name), modelOrder(rhs.name))
        }
    }

    /// Lexicographic comparison, newest first.
    private static func isDescending(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right { return left > right }
        return lhs.count > rhs.count
    }

    private static func version(_ value: String) -> [Int] {
        value.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Sorts iPhone names by their number, with Pro Max above Pro above plain.
    private static func modelOrder(_ name: String) -> [Int] {
        let number = name.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first ?? 0
        let variant = if name.contains("Pro Max") {
            3
        } else if name.contains("Pro") {
            2
        } else if name.contains("Plus") || name.contains("Air") {
            1
        } else {
            0
        }
        return [number, variant]
    }
}
