// GuestOS.swift — Supported guest operating system types.
// VortexCore

/// The guest operating system a VM is configured to run.
public enum GuestOS: String, Codable, Sendable, CaseIterable {
    /// macOS on Apple Silicon (ARM64).
    case macOS

    /// Linux on ARM64 (AArch64).
    case linuxARM64

    /// Windows on ARM (AArch64).
    case windowsARM
}

// MARK: - Display helpers

extension GuestOS {
    /// A human-readable display name.
    public var displayName: String {
        switch self {
        case .macOS:      return "macOS"
        case .linuxARM64: return "Linux (ARM64)"
        case .windowsARM: return "Windows (ARM)"
        }
    }

    /// The default boot mechanism for this guest OS.
    public var defaultBootMode: BootMode {
        switch self {
        case .macOS:      return .macOS
        case .linuxARM64: return .uefi
        case .windowsARM: return .uefi
        }
    }

    /// Whether this guest OS supports Rosetta translation.
    public var supportsRosetta: Bool {
        self == .linuxARM64
    }

    /// Whether this guest OS supports the macOS clipboard sharing mechanism.
    public var supportsClipboardSharing: Bool {
        self == .macOS
    }

    /// Whether this guest OS supports VirtioFS shared folders.
    public var supportsSharedFolders: Bool {
        switch self {
        case .macOS:      return true
        case .linuxARM64: return true
        case .windowsARM: return false
        }
    }
}
