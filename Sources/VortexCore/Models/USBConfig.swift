// USBConfig.swift — USB device passthrough configuration.
// VortexCore

/// Configuration for USB device support within a VM.
public struct USBConfig: Codable, Sendable, Hashable {
    /// Whether USB device support is enabled.
    public var enabled: Bool

    /// Devices that should be automatically attached when the VM starts.
    public var autoAttachDevices: [USBDeviceIdentifier]

    public init(
        enabled: Bool = false,
        autoAttachDevices: [USBDeviceIdentifier] = []
    ) {
        self.enabled = enabled
        self.autoAttachDevices = autoAttachDevices
    }

    /// USB disabled.
    public static let disabled = USBConfig(enabled: false)

    /// USB enabled with no auto-attach devices.
    public static let enabled = USBConfig(enabled: true)
}

/// Identifies a USB device by its vendor and product IDs.
public struct USBDeviceIdentifier: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(vendorID):\(productID)" }

    /// USB vendor ID (e.g. `0x05AC` for Apple).
    public var vendorID: UInt16

    /// USB product ID.
    public var productID: UInt16

    /// Optional human-readable label for display.
    public var label: String?

    public init(vendorID: UInt16, productID: UInt16, label: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.label = label
    }

    /// Formatted vendor:product string (e.g. `"05ac:8600"`).
    public var formattedID: String {
        String(format: "%04x:%04x", vendorID, productID)
    }
}
