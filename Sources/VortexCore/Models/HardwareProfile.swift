// HardwareProfile.swift — CPU and memory configuration with validation.
// VortexCore

import Foundation

/// CPU and memory allocation for a virtual machine.
public struct HardwareProfile: Codable, Sendable, Hashable {

    // MARK: - CPU

    /// Number of virtual CPU cores allocated to the VM.
    public var cpuCoreCount: Int

    // MARK: - Memory

    /// Amount of RAM in bytes allocated to the VM.
    public var memorySize: UInt64

    // MARK: - Init

    public init(cpuCoreCount: Int, memorySize: UInt64) {
        self.cpuCoreCount = cpuCoreCount
        self.memorySize = memorySize
    }

    /// Create a hardware profile specifying memory in GiB.
    public init(cpuCoreCount: Int, memoryGiB: UInt64) {
        self.cpuCoreCount = cpuCoreCount
        self.memorySize = memoryGiB * 1024 * 1024 * 1024
    }

    // MARK: - Constraints

    /// Absolute minimum CPU cores allowed.
    public static let minimumCPUCores: Int = 1

    /// Absolute minimum memory allowed (512 MiB).
    public static let minimumMemory: UInt64 = 512 * 1024 * 1024

    /// Maximum CPU cores: total physical cores on the host.
    public static var maximumCPUCores: Int {
        ProcessInfo.processInfo.processorCount
    }

    /// Maximum memory: total physical RAM on the host.
    public static var maximumMemory: UInt64 {
        UInt64(ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - Validation

    /// Validates the hardware profile against host capabilities and returns
    /// a list of issues. An empty array means the profile is valid.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if cpuCoreCount < Self.minimumCPUCores {
            issues.append(.cpuCoresTooLow(requested: cpuCoreCount, minimum: Self.minimumCPUCores))
        }
        if cpuCoreCount > Self.maximumCPUCores {
            issues.append(.cpuCoresTooHigh(requested: cpuCoreCount, maximum: Self.maximumCPUCores))
        }
        if memorySize < Self.minimumMemory {
            issues.append(.memoryTooLow(requested: memorySize, minimum: Self.minimumMemory))
        }
        if memorySize > Self.maximumMemory {
            issues.append(.memoryTooHigh(requested: memorySize, maximum: Self.maximumMemory))
        }

        return issues
    }

    /// Whether the profile passes all validation checks.
    public var isValid: Bool {
        validate().isEmpty
    }

    // MARK: - Convenience display

    /// Memory size formatted in human-readable GiB.
    public var memoryGiB: Double {
        Double(memorySize) / (1024.0 * 1024.0 * 1024.0)
    }

    /// Memory size formatted as a display string (e.g. "8 GiB").
    public var memoryDisplayString: String {
        let gib = memoryGiB
        if gib == gib.rounded() {
            return "\(Int(gib)) GiB"
        }
        return String(format: "%.1f GiB", gib)
    }

    // MARK: - Factory presets

    /// Lightweight profile: 2 cores, 2 GiB RAM.
    public static let lightweight = HardwareProfile(cpuCoreCount: 2, memoryGiB: 2)

    /// Standard profile: 4 cores, 8 GiB RAM.
    public static let standard = HardwareProfile(cpuCoreCount: 4, memoryGiB: 8)

    /// Performance profile: 8 cores, 16 GiB RAM.
    public static let performance = HardwareProfile(cpuCoreCount: 8, memoryGiB: 16)
}

// MARK: - Validation issues

extension HardwareProfile {
    /// Describes a single validation failure for a hardware profile.
    public enum ValidationIssue: Sendable, Hashable {
        case cpuCoresTooLow(requested: Int, minimum: Int)
        case cpuCoresTooHigh(requested: Int, maximum: Int)
        case memoryTooLow(requested: UInt64, minimum: UInt64)
        case memoryTooHigh(requested: UInt64, maximum: UInt64)

        /// Human-readable description of the issue.
        public var description: String {
            switch self {
            case .cpuCoresTooLow(let requested, let minimum):
                return "CPU core count \(requested) is below the minimum of \(minimum)."
            case .cpuCoresTooHigh(let requested, let maximum):
                return "CPU core count \(requested) exceeds the host maximum of \(maximum)."
            case .memoryTooLow(let requested, let minimum):
                return "Memory \(formatBytes(requested)) is below the minimum of \(formatBytes(minimum))."
            case .memoryTooHigh(let requested, let maximum):
                return "Memory \(formatBytes(requested)) exceeds the host physical memory of \(formatBytes(maximum))."
            }
        }

        private func formatBytes(_ bytes: UInt64) -> String {
            let gib = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
            if gib == gib.rounded() {
                return "\(Int(gib)) GiB"
            }
            return String(format: "%.1f GiB", gib)
        }
    }
}
