// VirtioDeviceBase.swift — Base class for all virtio device emulations.
// VortexDevices
//
// Implements the Virtio 1.2 device model including:
//   - Device status state machine (Section 2.1)
//   - Feature negotiation (Section 2.2)
//   - Virtqueue management (Section 2.7)
//   - Common Configuration structure (Section 4.1.4.3)
//   - ISR status register (Section 4.1.4.5)
//   - Notification structure (Section 4.1.4.4)
//   - Device-specific configuration (Section 4.1.4.6)
//
// Subclasses implement device-specific behavior by overriding:
//   handleQueueNotification(_:), readDeviceConfig(_:_:), writeDeviceConfig(_:_:_:),
//   deviceReset(), deviceActivated()
//
// Threading model: All common config reads/writes are called from the vCPU exit
// handler thread. Queue notifications may come from the notification doorbell
// (also vCPU thread). Subclasses that do async I/O must arrange their own dispatch.

import Foundation
import VortexCore

// MARK: - Virtio Device Status (Section 2.1)

/// The device status field tracks the guest driver's progress through initialization.
public struct VirtioDeviceStatus: OptionSet, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Guest OS has found the device and recognizes it as a valid virtio device.
    public static let acknowledge  = VirtioDeviceStatus(rawValue: 1 << 0)
    /// Guest OS knows how to drive the device (driver loaded).
    public static let driver       = VirtioDeviceStatus(rawValue: 1 << 1)
    /// Driver is ready and has set up virtqueues.
    public static let driverOK     = VirtioDeviceStatus(rawValue: 1 << 2)
    /// Driver has acknowledged all features it understands.
    public static let featuresOK   = VirtioDeviceStatus(rawValue: 1 << 3)
    /// Device has experienced an unrecoverable error.
    public static let needsReset   = VirtioDeviceStatus(rawValue: 1 << 6)
    /// Something went wrong in the guest. Writing 0 triggers a device reset.
    public static let failed       = VirtioDeviceStatus(rawValue: 1 << 7)

    public var description: String {
        var parts: [String] = []
        if contains(.acknowledge) { parts.append("ACKNOWLEDGE") }
        if contains(.driver) { parts.append("DRIVER") }
        if contains(.featuresOK) { parts.append("FEATURES_OK") }
        if contains(.driverOK) { parts.append("DRIVER_OK") }
        if contains(.needsReset) { parts.append("NEEDS_RESET") }
        if contains(.failed) { parts.append("FAILED") }
        return parts.isEmpty ? "RESET" : parts.joined(separator: "|")
    }
}

// MARK: - Virtio Common Feature Bits (Section 6)

/// Feature bits common to all virtio devices.
public enum VirtioFeature {
    /// Virtio 1.0+ compliant device (must be negotiated for modern devices).
    public static let version1: UInt64         = 1 << 32

    /// Negotiating this feature indicates the driver can use event index
    /// suppression for virtqueue notifications.
    public static let eventIdx: UInt64         = 1 << 29

    /// The device supports indirect descriptors.
    public static let indirectDesc: UInt64     = 1 << 28

    /// The device supports the ring reset operation.
    public static let ringReset: UInt64        = 1 << 40

    /// Access platform: device must use IOMMU for DMA.
    public static let accessPlatform: UInt64   = 1 << 33
}

// MARK: - Virtio PCI Capability Types (Section 4.1.4)

/// Vendor-specific PCI capability types for virtio-pci.
public enum VirtioPCICapType: UInt8, Sendable {
    /// Common configuration structure.
    case commonCfg = 1
    /// Notifications structure (doorbell).
    case notifyCfg = 2
    /// ISR status.
    case isrCfg = 3
    /// Device-specific configuration.
    case deviceCfg = 4
    /// PCI configuration access (for legacy systems).
    case pciCfg = 5
    /// Shared memory region.
    case sharedMemory = 8
}

// MARK: - Common Configuration Register Offsets (Section 4.1.4.3)

/// Register offsets within the virtio common configuration structure.
/// All multi-byte values are little-endian.
public enum VirtioCommonCfgOffset {
    /// RW: Device feature select (selects which 32-bit feature word to read).
    public static let deviceFeatureSelect: Int  = 0x00
    /// RO: Device features (32 bits of the selected feature word).
    public static let deviceFeature: Int        = 0x04
    /// RW: Driver feature select (selects which 32-bit feature word to write).
    public static let driverFeatureSelect: Int  = 0x08
    /// RW: Driver features (32 bits of the selected feature word).
    public static let driverFeature: Int        = 0x0C
    /// RW: MSI-X configuration vector.
    public static let configMsixVector: Int     = 0x10
    /// RO: Number of virtqueues.
    public static let numQueues: Int            = 0x12
    /// RW: Device status.
    public static let deviceStatus: Int         = 0x14
    /// RO: Configuration generation counter.
    public static let configGeneration: Int     = 0x15
    /// RW: Queue select (selects which queue subsequent queue fields refer to).
    public static let queueSelect: Int          = 0x16
    /// RW: Queue size (0 = queue not available).
    public static let queueSize: Int            = 0x18
    /// RW: Queue MSI-X vector.
    public static let queueMsixVector: Int      = 0x1A
    /// RW: Queue enable.
    public static let queueEnable: Int          = 0x1C
    /// RO: Queue notify offset (relative to notification base).
    public static let queueNotifyOff: Int       = 0x1E
    /// RW: Queue descriptor table address (low 32 bits).
    public static let queueDescLow: Int         = 0x20
    /// RW: Queue descriptor table address (high 32 bits).
    public static let queueDescHigh: Int        = 0x24
    /// RW: Queue available ring address (low 32 bits).
    public static let queueAvailLow: Int        = 0x28
    /// RW: Queue available ring address (high 32 bits).
    public static let queueAvailHigh: Int       = 0x2C
    /// RW: Queue used ring address (low 32 bits).
    public static let queueUsedLow: Int         = 0x30
    /// RW: Queue used ring address (high 32 bits).
    public static let queueUsedHigh: Int        = 0x34

    /// Total size of the common configuration structure.
    public static let structSize: Int           = 0x38
}

// MARK: - VirtioDeviceBase

/// Base class for all virtio device emulations.
///
/// Manages the virtio device lifecycle, feature negotiation, virtqueue setup,
/// and common configuration register access. Subclasses implement the
/// device-specific protocol by overriding the abstract methods.
///
/// ## Subclassing
///
/// Override these methods:
/// - `handleQueueNotification(_:)` — process I/O on a specific virtqueue
/// - `readDeviceConfig(offset:size:)` — device-specific config reads
/// - `writeDeviceConfig(offset:size:value:)` — device-specific config writes
/// - `deviceReset()` — reset device-specific state
/// - `deviceActivated()` — called when driver completes initialization
///
/// ## Ownership
///
/// VirtioDeviceBase owns the `VirtQueue` instances. The transport (VirtioTransport)
/// delegates common config and notification handling here.
open class VirtioDeviceBase: @unchecked Sendable {

    // MARK: - Device Identity

    /// The type of virtio device (block, net, sound, etc.).
    public let deviceType: VirtioDeviceType

    /// Number of virtqueues this device uses.
    public let numQueues: Int

    /// Size of the device-specific configuration space in bytes.
    public let deviceConfigSize: Int

    /// Features offered by the device (includes VIRTIO_F_VERSION_1).
    public let deviceFeatures: UInt64

    // MARK: - State

    /// Current device status (written by the guest driver).
    public private(set) var status: VirtioDeviceStatus = []

    /// Features accepted by the guest driver (subset of deviceFeatures).
    public private(set) var driverFeatures: UInt64 = 0

    /// Generation counter for device-specific configuration.
    /// Incremented when the device changes config asynchronously.
    public private(set) var configGeneration: UInt8 = 0

    /// The virtqueues owned by this device.
    public private(set) var queues: [VirtQueue] = []

    /// MSI-X vector for configuration change notifications, or 0xFFFF.
    public var configMsixVector: UInt16 = 0xFFFF

    /// Default queue size for newly created queues.
    public let defaultQueueSize: UInt16

    // MARK: - Feature Selection Registers

    /// Which 32-bit word of device features to expose (0 = bits 0-31, 1 = bits 32-63).
    private var deviceFeatureSelect: UInt32 = 0
    /// Which 32-bit word of driver features to accept.
    private var driverFeatureSelect: UInt32 = 0

    // MARK: - Queue Selection

    /// The currently selected queue index for configuration register access.
    private var selectedQueueIndex: UInt16 = 0

    /// Guest memory accessor, set during queue creation.
    private var guestMemory: (any GuestMemoryAccessor)?

    /// Callback invoked when the device needs to send an interrupt.
    /// The transport sets this to route interrupts through MSI-X or INTx.
    ///
    /// Parameter 1: queue index (or -1 for config change)
    /// Parameter 2: MSI-X vector
    public var interruptHandler: ((_ queueIndex: Int, _ msixVector: UInt16) -> Void)?

    // MARK: - Initialization

    /// Initialize a virtio device base.
    ///
    /// - Parameters:
    ///   - deviceType: The virtio device type (determines PCI device ID).
    ///   - numQueues: Number of virtqueues this device needs.
    ///   - deviceFeatures: Feature bits the device offers (VIRTIO_F_VERSION_1 is
    ///     always included automatically).
    ///   - configSize: Size of the device-specific configuration space in bytes.
    ///   - defaultQueueSize: Default maximum depth for each virtqueue (power of 2).
    public init(
        deviceType: VirtioDeviceType,
        numQueues: Int,
        deviceFeatures: UInt64,
        configSize: Int,
        defaultQueueSize: UInt16 = 256
    ) {
        self.deviceType = deviceType
        self.numQueues = numQueues
        self.deviceFeatures = deviceFeatures | VirtioFeature.version1
        self.deviceConfigSize = configSize
        self.defaultQueueSize = defaultQueueSize
    }

    /// Set the guest memory accessor and create all virtqueues.
    ///
    /// Must be called before the device can be used. Typically called by
    /// VirtioTransport during PCI bus enumeration or device attachment.
    ///
    /// - Parameter memory: The guest memory accessor for virtqueue operations.
    public func attachGuestMemory(_ memory: any GuestMemoryAccessor) {
        self.guestMemory = memory
        self.queues = (0..<numQueues).map { i in
            VirtQueue(index: UInt16(i), size: defaultQueueSize, guestMemory: memory)
        }
    }

    // MARK: - Common Configuration Read

    /// Handle a read from the common configuration structure.
    ///
    /// - Parameters:
    ///   - offset: Byte offset within the common config structure.
    ///   - size: Read width in bytes (1, 2, or 4).
    /// - Returns: The register value.
    public func readCommonConfig(offset: Int, size: Int) -> UInt32 {
        switch offset {
        case VirtioCommonCfgOffset.deviceFeatureSelect:
            return deviceFeatureSelect

        case VirtioCommonCfgOffset.deviceFeature:
            return selectedDeviceFeatureWord()

        case VirtioCommonCfgOffset.driverFeatureSelect:
            return driverFeatureSelect

        case VirtioCommonCfgOffset.driverFeature:
            return selectedDriverFeatureWord()

        case VirtioCommonCfgOffset.configMsixVector:
            return UInt32(configMsixVector)

        case VirtioCommonCfgOffset.numQueues:
            return UInt32(numQueues)

        case VirtioCommonCfgOffset.deviceStatus:
            return UInt32(status.rawValue)

        case VirtioCommonCfgOffset.configGeneration:
            return UInt32(configGeneration)

        case VirtioCommonCfgOffset.queueSelect:
            return UInt32(selectedQueueIndex)

        case VirtioCommonCfgOffset.queueSize:
            return UInt32(selectedQueue?.queueSize ?? 0)

        case VirtioCommonCfgOffset.queueMsixVector:
            return UInt32(selectedQueue?.msixVector ?? 0xFFFF)

        case VirtioCommonCfgOffset.queueEnable:
            return (selectedQueue?.isEnabled ?? false) ? 1 : 0

        case VirtioCommonCfgOffset.queueNotifyOff:
            // Each queue gets its own notification offset.
            // The actual address = notify_base + queue_notify_off * notify_off_multiplier
            return UInt32(selectedQueueIndex)

        case VirtioCommonCfgOffset.queueDescLow:
            return UInt32(truncatingIfNeeded: selectedQueue?.descriptorTableAddress ?? 0)

        case VirtioCommonCfgOffset.queueDescHigh:
            return UInt32(truncatingIfNeeded: (selectedQueue?.descriptorTableAddress ?? 0) >> 32)

        case VirtioCommonCfgOffset.queueAvailLow:
            return UInt32(truncatingIfNeeded: selectedQueue?.availRingAddress ?? 0)

        case VirtioCommonCfgOffset.queueAvailHigh:
            return UInt32(truncatingIfNeeded: (selectedQueue?.availRingAddress ?? 0) >> 32)

        case VirtioCommonCfgOffset.queueUsedLow:
            return UInt32(truncatingIfNeeded: selectedQueue?.usedRingAddress ?? 0)

        case VirtioCommonCfgOffset.queueUsedHigh:
            return UInt32(truncatingIfNeeded: (selectedQueue?.usedRingAddress ?? 0) >> 32)

        default:
            return 0
        }
    }

    // MARK: - Common Configuration Write

    /// Handle a write to the common configuration structure.
    ///
    /// - Parameters:
    ///   - offset: Byte offset within the common config structure.
    ///   - size: Write width in bytes (1, 2, or 4).
    ///   - value: The value written by the guest.
    public func writeCommonConfig(offset: Int, size: Int, value: UInt32) {
        switch offset {
        case VirtioCommonCfgOffset.deviceFeatureSelect:
            deviceFeatureSelect = value

        case VirtioCommonCfgOffset.driverFeatureSelect:
            driverFeatureSelect = value

        case VirtioCommonCfgOffset.driverFeature:
            writeDriverFeatureWord(value)

        case VirtioCommonCfgOffset.configMsixVector:
            configMsixVector = UInt16(truncatingIfNeeded: value)

        case VirtioCommonCfgOffset.deviceStatus:
            handleStatusWrite(UInt8(truncatingIfNeeded: value))

        case VirtioCommonCfgOffset.queueSelect:
            selectedQueueIndex = UInt16(truncatingIfNeeded: value)

        case VirtioCommonCfgOffset.queueSize:
            // Guest can reduce queue size but not exceed our maximum.
            if let queue = selectedQueue {
                let requested = UInt16(truncatingIfNeeded: value)
                if requested > 0 && requested <= queue.queueSize {
                    // Queue size is fixed at creation; the guest reads our size and
                    // must accept it. We allow writes but ignore size changes after
                    // creation per the modern virtio-pci spec.
                }
            }

        case VirtioCommonCfgOffset.queueMsixVector:
            selectedQueue?.msixVector = UInt16(truncatingIfNeeded: value)

        case VirtioCommonCfgOffset.queueEnable:
            if value == 1 {
                selectedQueue?.enable()
            }

        case VirtioCommonCfgOffset.queueDescLow:
            if let queue = selectedQueue {
                let current = queue.descriptorTableAddress
                let newAddr = (current & 0xFFFF_FFFF_0000_0000) | UInt64(value)
                queue.setDescriptorTable(address: newAddr)
            }

        case VirtioCommonCfgOffset.queueDescHigh:
            if let queue = selectedQueue {
                let current = queue.descriptorTableAddress
                let newAddr = (current & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
                queue.setDescriptorTable(address: newAddr)
            }

        case VirtioCommonCfgOffset.queueAvailLow:
            if let queue = selectedQueue {
                let current = queue.availRingAddress
                let newAddr = (current & 0xFFFF_FFFF_0000_0000) | UInt64(value)
                queue.setAvailRing(address: newAddr)
            }

        case VirtioCommonCfgOffset.queueAvailHigh:
            if let queue = selectedQueue {
                let current = queue.availRingAddress
                let newAddr = (current & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
                queue.setAvailRing(address: newAddr)
            }

        case VirtioCommonCfgOffset.queueUsedLow:
            if let queue = selectedQueue {
                let current = queue.usedRingAddress
                let newAddr = (current & 0xFFFF_FFFF_0000_0000) | UInt64(value)
                queue.setUsedRing(address: newAddr)
            }

        case VirtioCommonCfgOffset.queueUsedHigh:
            if let queue = selectedQueue {
                let current = queue.usedRingAddress
                let newAddr = (current & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
                queue.setUsedRing(address: newAddr)
            }

        default:
            break
        }
    }

    // MARK: - Notification Handling

    /// Called when the guest writes to the notification doorbell for a queue.
    ///
    /// The notification offset identifies which queue. This is the primary
    /// entry point for virtio I/O: the guest has posted descriptors and is
    /// kicking the device to process them.
    ///
    /// - Parameter queueIndex: The queue index that was notified.
    public func processNotification(queueIndex: Int) {
        guard queueIndex >= 0 && queueIndex < queues.count else { return }
        guard status.contains(.driverOK) else { return }
        handleQueueNotification(queueIndex: queueIndex)
    }

    // MARK: - Interrupt Delivery

    /// Signal the guest that used buffers are available on a queue.
    ///
    /// Checks the queue's notification suppression before firing. If MSI-X
    /// is configured, sends the queue's MSI-X vector; otherwise falls back
    /// to ISR status + INTx.
    ///
    /// - Parameter queueIndex: The queue that has new used entries.
    public func signalUsedBuffers(queueIndex: Int) {
        guard queueIndex >= 0 && queueIndex < queues.count else { return }
        let queue = queues[queueIndex]
        guard queue.needsNotification() else { return }

        isrStatus |= 0x01  // Queue interrupt bit
        interruptHandler?(queueIndex, queue.msixVector)
    }

    /// Signal the guest that the device configuration has changed.
    public func signalConfigChange() {
        configGeneration &+= 1
        isrStatus |= 0x02  // Config change bit
        interruptHandler?(-1, configMsixVector)
    }

    // MARK: - ISR Status

    /// ISR status register. Bit 0: queue interrupt. Bit 1: config change.
    /// Reading this register clears it (for non-MSI-X interrupt path).
    public private(set) var isrStatus: UInt8 = 0

    /// Read and clear the ISR status register.
    public func readAndClearISR() -> UInt8 {
        let value = isrStatus
        isrStatus = 0
        return value
    }

    // MARK: - Abstract Methods (Override in Subclasses)

    /// Process I/O on a specific virtqueue.
    ///
    /// Called when the guest writes to the notification doorbell for this queue.
    /// The subclass should dequeue descriptor chains, process I/O, and post
    /// results to the used ring.
    ///
    /// - Parameter queueIndex: The index of the notified queue.
    open func handleQueueNotification(queueIndex: Int) {
        // Subclasses must override.
    }

    /// Read from the device-specific configuration space.
    ///
    /// - Parameters:
    ///   - offset: Byte offset within the device config space.
    ///   - size: Read width in bytes (1, 2, or 4).
    /// - Returns: The configuration value.
    open func readDeviceConfig(offset: Int, size: Int) -> UInt32 {
        return 0 // Subclasses override.
    }

    /// Write to the device-specific configuration space.
    ///
    /// - Parameters:
    ///   - offset: Byte offset within the device config space.
    ///   - size: Write width in bytes (1, 2, or 4).
    ///   - value: The value written by the guest.
    open func writeDeviceConfig(offset: Int, size: Int, value: UInt32) {
        // Subclasses override.
    }

    /// Reset all device-specific state.
    ///
    /// Called when the guest writes 0 to the device status register. The subclass
    /// should cancel any pending I/O and return to the initial state.
    open func deviceReset() {
        // Subclasses override.
    }

    /// Called when the guest completes initialization (sets DRIVER_OK).
    ///
    /// At this point, feature negotiation is complete and queues are configured.
    /// The subclass can start processing I/O.
    open func deviceActivated() {
        // Subclasses override.
    }

    // MARK: - Private Helpers

    /// The currently selected queue, or nil if the index is out of range.
    private var selectedQueue: VirtQueue? {
        let idx = Int(selectedQueueIndex)
        guard idx >= 0 && idx < queues.count else { return nil }
        return queues[idx]
    }

    /// Return the 32-bit word of device features selected by deviceFeatureSelect.
    private func selectedDeviceFeatureWord() -> UInt32 {
        switch deviceFeatureSelect {
        case 0:
            return UInt32(truncatingIfNeeded: deviceFeatures)
        case 1:
            return UInt32(truncatingIfNeeded: deviceFeatures >> 32)
        default:
            return 0
        }
    }

    /// Return the 32-bit word of driver features selected by driverFeatureSelect.
    private func selectedDriverFeatureWord() -> UInt32 {
        switch driverFeatureSelect {
        case 0:
            return UInt32(truncatingIfNeeded: driverFeatures)
        case 1:
            return UInt32(truncatingIfNeeded: driverFeatures >> 32)
        default:
            return 0
        }
    }

    /// Write a 32-bit word of driver features.
    private func writeDriverFeatureWord(_ value: UInt32) {
        switch driverFeatureSelect {
        case 0:
            driverFeatures = (driverFeatures & 0xFFFF_FFFF_0000_0000) | UInt64(value)
        case 1:
            driverFeatures = (driverFeatures & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
        default:
            break
        }
    }

    /// Handle a write to the device status register.
    ///
    /// Implements the Virtio 1.2 device status state machine:
    /// - Writing 0 triggers a full device reset.
    /// - Bits are set incrementally: ACKNOWLEDGE → DRIVER → FEATURES_OK → DRIVER_OK.
    /// - Setting FEATURES_OK validates that the negotiated features are acceptable.
    /// - Setting DRIVER_OK activates the device.
    private func handleStatusWrite(_ value: UInt8) {
        let newStatus = VirtioDeviceStatus(rawValue: value)

        // Writing 0 means "reset the device".
        if value == 0 {
            performFullReset()
            return
        }

        // Validate the FEATURES_OK transition: the driver's feature set must be
        // a valid subset of what the device offered.
        if newStatus.contains(.featuresOK) && !status.contains(.featuresOK) {
            if !validateFeatures() {
                // Don't set FEATURES_OK — the driver will read back status and
                // see the bit missing, indicating feature negotiation failed.
                status = VirtioDeviceStatus(rawValue: value & ~VirtioDeviceStatus.featuresOK.rawValue)
                return
            }
            // Apply VIRTIO_F_EVENT_IDX to all queues if negotiated.
            let eventIdxNegotiated = (driverFeatures & VirtioFeature.eventIdx) != 0
            for queue in queues {
                queue.eventIdxEnabled = eventIdxNegotiated
            }
        }

        status = newStatus

        // When DRIVER_OK is set, the device is fully initialized.
        if newStatus.contains(.driverOK) && !status.contains(.needsReset) {
            deviceActivated()
        }
    }

    /// Validate that the driver's negotiated features are acceptable.
    ///
    /// - The driver must not request features the device didn't offer.
    /// - VIRTIO_F_VERSION_1 must always be negotiated (modern device requirement).
    private func validateFeatures() -> Bool {
        // Driver must not set bits the device didn't offer.
        let unsupported = driverFeatures & ~deviceFeatures
        guard unsupported == 0 else { return false }

        // Modern virtio-pci requires VIRTIO_F_VERSION_1.
        guard (driverFeatures & VirtioFeature.version1) != 0 else { return false }

        return true
    }

    /// Perform a full device reset: clear status, features, and all queues.
    private func performFullReset() {
        let previouslyActive = status.contains(.driverOK)

        status = []
        driverFeatures = 0
        deviceFeatureSelect = 0
        driverFeatureSelect = 0
        selectedQueueIndex = 0
        configMsixVector = 0xFFFF
        isrStatus = 0

        for queue in queues {
            queue.reset()
        }

        if previouslyActive {
            deviceReset()
        }
    }
}

// MARK: - VirtioDeviceType Numeric ID

extension VirtioDeviceType {
    /// The numeric virtio device type ID per the Virtio 1.2 specification (Section 5).
    ///
    /// Used to compute the PCI device ID: 0x1040 + typeID for modern virtio-pci.
    public var typeID: UInt16 {
        switch self {
        case .network:    return 1
        case .block:      return 2
        case .console:    return 3
        case .entropy:    return 4
        case .balloon:    return 5
        case .filesystem: return 9
        case .gpu:        return 16
        case .input:      return 18
        case .socket:     return 19
        case .sound:      return 25
        }
    }
}
