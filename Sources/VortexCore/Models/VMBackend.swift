// VMBackend.swift -- VM execution backend selection.
// VortexCore

/// The engine responsible for executing a VM.
public enum VMBackend: String, Codable, Sendable, Hashable, CaseIterable {
    /// Apple's Virtualization.framework backend.
    ///
    /// This remains the production backend for macOS guests and the compatibility
    /// backend for Linux and Windows guests.
    case appleVirtualization

    /// Vortex's native Hypervisor.framework backend.
    ///
    /// This backend is intended for Linux ARM64 guests where Vortex owns the
    /// virtual platform, devices, and block storage stack.
    case vortexHV
}

