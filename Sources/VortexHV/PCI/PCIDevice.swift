// PCIDevice.swift -- PCI device protocol and configuration space model.
// VortexHV
//
// Defines the protocol that all emulated PCI devices must conform to, plus
// the PCIConfigSpace struct that models the standard 256-byte Type 0 header.
// Also provides BAR type detection and a default config space implementation.

import Foundation

// MARK: - PCI Constants

/// Well-known PCI vendor IDs.
public enum PCIVendorID {
    /// Red Hat (virtio devices).
    public static let redHat: UInt16 = 0x1AF4
    /// Vortex vendor ID for custom devices (e.g., EQ2 audio).
    public static let vortex: UInt16 = 0x1D7E
}

/// PCI Command register bits (offset 0x04).
public struct PCICommandRegister: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// I/O space access enable.
    public static let ioSpace        = PCICommandRegister(rawValue: 1 << 0)
    /// Memory space access enable.
    public static let memorySpace    = PCICommandRegister(rawValue: 1 << 1)
    /// Bus master enable.
    public static let busMaster      = PCICommandRegister(rawValue: 1 << 2)
    /// Interrupt disable.
    public static let intxDisable    = PCICommandRegister(rawValue: 1 << 10)
}

/// PCI Status register bits (offset 0x06).
public struct PCIStatusRegister: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Capabilities list present.
    public static let capabilitiesList = PCIStatusRegister(rawValue: 1 << 4)
}

// MARK: - BAR Type

/// Describes the type of a PCI Base Address Register.
public enum BARType: Sendable {
    /// 32-bit memory BAR.
    case memory32
    /// 64-bit memory BAR (consumes this BAR and the next one).
    case memory64
    /// I/O space BAR.
    case io
    /// This BAR is the upper 32 bits of a 64-bit BAR pair.
    case memory64High
    /// BAR is not implemented (size == 0).
    case unused

    /// Decode the BAR type from a BAR value.
    public static func decode(_ barValue: UInt32) -> BARType {
        if (barValue & 0x1) != 0 {
            return .io
        }
        let memType = (barValue >> 1) & 0x3
        switch memType {
        case 0x0: return .memory32
        case 0x2: return .memory64
        default:  return .memory32 // Reserved, treat as 32-bit
        }
    }
}

// MARK: - BAR Info

/// Runtime information about an allocated BAR.
public struct BARInfo: Sendable {
    /// BAR index (0-5).
    public let index: Int
    /// BAR type.
    public let type: BARType
    /// Allocated guest physical address (0 if not yet allocated).
    public var address: UInt64
    /// Size of the BAR region in bytes.
    public let size: UInt64
    /// Whether this BAR is prefetchable.
    public let prefetchable: Bool

    public init(index: Int, type: BARType, address: UInt64 = 0, size: UInt64, prefetchable: Bool = false) {
        self.index = index
        self.type = type
        self.address = address
        self.size = size
        self.prefetchable = prefetchable
    }
}

// MARK: - PCI Config Space Header Offsets

/// Standard PCI Type 0 configuration space register offsets.
public enum PCIConfigOffset {
    public static let vendorID: Int            = 0x00
    public static let deviceID: Int            = 0x02
    public static let command: Int             = 0x04
    public static let status: Int              = 0x06
    public static let revisionID: Int          = 0x08
    public static let progIF: Int              = 0x09
    public static let subclass: Int            = 0x0A
    public static let classCode: Int           = 0x0B
    public static let cacheLineSize: Int       = 0x0C
    public static let latencyTimer: Int        = 0x0D
    public static let headerType: Int          = 0x0E
    public static let bist: Int                = 0x0F
    public static let bar0: Int                = 0x10
    public static let bar1: Int                = 0x14
    public static let bar2: Int                = 0x18
    public static let bar3: Int                = 0x1C
    public static let bar4: Int                = 0x20
    public static let bar5: Int                = 0x24
    public static let cardbusCISPointer: Int   = 0x28
    public static let subsystemVendorID: Int   = 0x2C
    public static let subsystemID: Int         = 0x2E
    public static let expansionROMBase: Int    = 0x30
    public static let capabilitiesPointer: Int = 0x34
    public static let interruptLine: Int       = 0x3C
    public static let interruptPin: Int        = 0x3D
    public static let minGrant: Int            = 0x3E
    public static let maxLatency: Int          = 0x3F
}

// MARK: - PCI Config Space

/// Represents the 256-byte PCI Type 0 configuration space header.
///
/// Provides raw byte-level access and typed accessors for standard fields.
/// Devices store their configuration state in this struct and the PCIBus reads/writes
/// it when the guest accesses ECAM space.
public struct PCIConfigSpace: Sendable {
    /// The raw 256-byte configuration space.
    public var data: [UInt8]

    // MARK: - Initialization

    /// Create a config space with all zeros.
    public init() {
        data = [UInt8](repeating: 0, count: 256)
    }

    /// Create a config space with the essential identity fields pre-populated.
    public init(
        vendorID: UInt16,
        deviceID: UInt16,
        revisionID: UInt8 = 0x01,
        classCode: UInt8,
        subclass: UInt8,
        progIF: UInt8 = 0x00,
        subsystemVendorID: UInt16 = 0,
        subsystemID: UInt16 = 0,
        interruptPin: UInt8 = 0x01, // INTA#
        headerType: UInt8 = 0x00    // Type 0 (endpoint)
    ) {
        data = [UInt8](repeating: 0, count: 256)
        self.vendorID = vendorID
        self.deviceID = deviceID
        self.revisionID = revisionID
        self.classCode = classCode
        self.subclass = subclass
        self.progIF = progIF
        self.headerType = headerType
        self.subsystemVendorID = subsystemVendorID
        self.subsystemID = subsystemID
        self.interruptPin = interruptPin
        // Report capabilities list in status register.
        self.status = PCIStatusRegister.capabilitiesList.rawValue
    }

    // MARK: - Typed Field Accessors

    public var vendorID: UInt16 {
        get { read16(at: PCIConfigOffset.vendorID) }
        set { write16(at: PCIConfigOffset.vendorID, value: newValue) }
    }

    public var deviceID: UInt16 {
        get { read16(at: PCIConfigOffset.deviceID) }
        set { write16(at: PCIConfigOffset.deviceID, value: newValue) }
    }

    public var command: UInt16 {
        get { read16(at: PCIConfigOffset.command) }
        set { write16(at: PCIConfigOffset.command, value: newValue) }
    }

    public var status: UInt16 {
        get { read16(at: PCIConfigOffset.status) }
        set { write16(at: PCIConfigOffset.status, value: newValue) }
    }

    public var revisionID: UInt8 {
        get { data[PCIConfigOffset.revisionID] }
        set { data[PCIConfigOffset.revisionID] = newValue }
    }

    public var progIF: UInt8 {
        get { data[PCIConfigOffset.progIF] }
        set { data[PCIConfigOffset.progIF] = newValue }
    }

    public var subclass: UInt8 {
        get { data[PCIConfigOffset.subclass] }
        set { data[PCIConfigOffset.subclass] = newValue }
    }

    public var classCode: UInt8 {
        get { data[PCIConfigOffset.classCode] }
        set { data[PCIConfigOffset.classCode] = newValue }
    }

    public var headerType: UInt8 {
        get { data[PCIConfigOffset.headerType] }
        set { data[PCIConfigOffset.headerType] = newValue }
    }

    public var capabilitiesPointer: UInt8 {
        get { data[PCIConfigOffset.capabilitiesPointer] }
        set { data[PCIConfigOffset.capabilitiesPointer] = newValue }
    }

    public var interruptLine: UInt8 {
        get { data[PCIConfigOffset.interruptLine] }
        set { data[PCIConfigOffset.interruptLine] = newValue }
    }

    public var interruptPin: UInt8 {
        get { data[PCIConfigOffset.interruptPin] }
        set { data[PCIConfigOffset.interruptPin] = newValue }
    }

    public var subsystemVendorID: UInt16 {
        get { read16(at: PCIConfigOffset.subsystemVendorID) }
        set { write16(at: PCIConfigOffset.subsystemVendorID, value: newValue) }
    }

    public var subsystemID: UInt16 {
        get { read16(at: PCIConfigOffset.subsystemID) }
        set { write16(at: PCIConfigOffset.subsystemID, value: newValue) }
    }

    // MARK: - BAR Accessors

    /// Read a BAR register by index (0-5).
    public func barValue(at index: Int) -> UInt32 {
        guard index >= 0 && index < 6 else { return 0 }
        return read32(at: PCIConfigOffset.bar0 + index * 4)
    }

    /// Write a BAR register by index (0-5).
    public mutating func setBarValue(at index: Int, value: UInt32) {
        guard index >= 0 && index < 6 else { return }
        write32(at: PCIConfigOffset.bar0 + index * 4, value: value)
    }

    // MARK: - Raw Byte Access

    /// Read a single byte from the config space.
    public func read8(at offset: Int) -> UInt8 {
        guard offset >= 0 && offset < data.count else { return 0xFF }
        return data[offset]
    }

    /// Write a single byte to the config space.
    public mutating func write8(at offset: Int, value: UInt8) {
        guard offset >= 0 && offset < data.count else { return }
        data[offset] = value
    }

    /// Read a 16-bit little-endian value.
    public func read16(at offset: Int) -> UInt16 {
        guard offset >= 0 && offset + 1 < data.count else { return 0xFFFF }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /// Write a 16-bit little-endian value.
    public mutating func write16(at offset: Int, value: UInt16) {
        guard offset >= 0 && offset + 1 < data.count else { return }
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    /// Read a 32-bit little-endian value.
    public func read32(at offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 3 < data.count else { return 0xFFFF_FFFF }
        return UInt32(data[offset])
             | (UInt32(data[offset + 1]) << 8)
             | (UInt32(data[offset + 2]) << 16)
             | (UInt32(data[offset + 3]) << 24)
    }

    /// Write a 32-bit little-endian value.
    public mutating func write32(at offset: Int, value: UInt32) {
        guard offset >= 0 && offset + 3 < data.count else { return }
        data[offset]     = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

// MARK: - PCI Device Emulation Protocol

/// Protocol that all emulated PCI devices must conform to.
///
/// The PCI bus calls these methods when the guest accesses config space or
/// memory-mapped BAR regions of this device.
///
/// **Threading**: Config space reads/writes are called from the vCPU thread
/// (serialized by the ECAM MMIO handler). BAR reads/writes may be called
/// concurrently from any vCPU thread; implementations must be thread-safe.
public protocol PCIDeviceEmulation: AnyObject, Sendable {
    /// The device's PCI configuration space.
    var configSpace: PCIConfigSpace { get set }

    /// Information about each BAR this device implements.
    /// Only BARs with non-zero size are considered implemented.
    var bars: [BARInfo] { get set }

    /// Read from the PCI configuration space at the given byte offset.
    ///
    /// The default implementation reads from the `configSpace` struct.
    /// Devices that need custom behavior for certain registers (e.g., virtio
    /// device config) should override and fall through to the default for
    /// standard offsets.
    ///
    /// - Parameters:
    ///   - offset: Byte offset within the 256-byte config space (or extended space).
    ///   - size: Access width in bytes (1, 2, or 4).
    /// - Returns: The value read, zero-extended to UInt32.
    func readConfig(offset: Int, size: Int) -> UInt32

    /// Write to the PCI configuration space at the given byte offset.
    ///
    /// - Parameters:
    ///   - offset: Byte offset within the 256-byte config space.
    ///   - size: Access width in bytes (1, 2, or 4).
    ///   - value: The value to write.
    func writeConfig(offset: Int, size: Int, value: UInt32)

    /// Read from a device BAR region.
    ///
    /// - Parameters:
    ///   - bar: BAR index (0-5).
    ///   - offset: Byte offset within the BAR region.
    ///   - size: Access width in bytes (1, 2, 4, or 8).
    /// - Returns: The value read.
    func readBAR(bar: Int, offset: UInt64, size: Int) -> UInt64

    /// Write to a device BAR region.
    ///
    /// - Parameters:
    ///   - bar: BAR index (0-5).
    ///   - offset: Byte offset within the BAR region.
    ///   - size: Access width in bytes (1, 2, 4, or 8).
    ///   - value: The value to write.
    func writeBAR(bar: Int, offset: UInt64, size: Int, value: UInt64)

    /// Called after the device is added to the PCI bus and BARs are allocated.
    /// The device can perform any setup that depends on knowing its BAR addresses.
    func didAllocateBARs()
}

// MARK: - Default Implementations

extension PCIDeviceEmulation {

    /// Default config space read: read raw bytes from the configSpace struct.
    public func readConfig(offset: Int, size: Int) -> UInt32 {
        switch size {
        case 1:
            return UInt32(configSpace.read8(at: offset))
        case 2:
            return UInt32(configSpace.read16(at: offset))
        case 4:
            return configSpace.read32(at: offset)
        default:
            return 0xFFFF_FFFF
        }
    }

    /// Default config space write: handles standard header fields with proper
    /// read-only masking and BAR sizing protocol.
    public func writeConfig(offset: Int, size: Int, value: UInt32) {
        switch offset {
        case PCIConfigOffset.vendorID, PCIConfigOffset.deviceID:
            // Read-only -- ignore writes.
            return

        case PCIConfigOffset.status:
            // Status register: write-1-to-clear for error bits (bits 15:11).
            let current = configSpace.status
            let w1cMask: UInt16 = 0xF800
            let clearedBits = UInt16(truncatingIfNeeded: value) & w1cMask
            configSpace.status = current & ~clearedBits
            return

        case PCIConfigOffset.revisionID, PCIConfigOffset.progIF,
             PCIConfigOffset.subclass, PCIConfigOffset.classCode,
             PCIConfigOffset.headerType:
            // Read-only identity fields.
            return

        case PCIConfigOffset.bar0, PCIConfigOffset.bar1,
             PCIConfigOffset.bar2, PCIConfigOffset.bar3,
             PCIConfigOffset.bar4, PCIConfigOffset.bar5:
            handleBARWrite(offset: offset, value: value)
            return

        case PCIConfigOffset.subsystemVendorID, PCIConfigOffset.subsystemID:
            // Read-only.
            return

        case PCIConfigOffset.capabilitiesPointer:
            // Read-only.
            return

        default:
            break
        }

        // For all other offsets, write the value directly.
        switch size {
        case 1:
            configSpace.write8(at: offset, value: UInt8(truncatingIfNeeded: value))
        case 2:
            configSpace.write16(at: offset, value: UInt16(truncatingIfNeeded: value))
        case 4:
            configSpace.write32(at: offset, value: value)
        default:
            break
        }
    }

    /// Default BAR read: returns 0.
    public func readBAR(bar: Int, offset: UInt64, size: Int) -> UInt64 {
        return 0
    }

    /// Default BAR write: no-op.
    public func writeBAR(bar: Int, offset: UInt64, size: Int, value: UInt64) {
        // No-op by default.
    }

    /// Default didAllocateBARs: no-op.
    public func didAllocateBARs() {
        // No-op by default.
    }

    // MARK: - BAR Write Handling

    /// Handle guest writes to BAR registers. Implements the standard BAR sizing
    /// protocol: writing all-ones returns the BAR size mask; writing an address
    /// programs the BAR base.
    private func handleBARWrite(offset: Int, value: UInt32) {
        let barIndex = (offset - PCIConfigOffset.bar0) / 4
        guard barIndex >= 0 && barIndex < bars.count else { return }
        let barInfo = bars[barIndex]

        // Skip high-half BARs of 64-bit pairs -- those are handled by the low half.
        if barInfo.type == .memory64High { return }

        if barInfo.type == .unused { return }

        if value == 0xFFFF_FFFF {
            // BAR sizing: guest is probing the BAR size.
            // Return the size mask with low bits set for the BAR type.
            let sizeMask = ~(UInt32(truncatingIfNeeded: barInfo.size) - 1)
            var result = sizeMask

            switch barInfo.type {
            case .memory32:
                result &= 0xFFFF_FFF0 // Clear lower 4 bits
                if barInfo.prefetchable { result |= 0x08 }
            case .memory64:
                result &= 0xFFFF_FFF0
                result |= 0x04 // Type = 64-bit
                if barInfo.prefetchable { result |= 0x08 }
            case .io:
                result &= 0xFFFF_FFFC // Clear lower 2 bits
                result |= 0x01        // I/O space indicator
            case .memory64High, .unused:
                break
            }

            configSpace.setBarValue(at: barIndex, value: result)

            // For 64-bit BARs, also set the high half size mask.
            if barInfo.type == .memory64 && barIndex + 1 < 6 {
                let highMask = UInt32(truncatingIfNeeded: (~(barInfo.size - 1)) >> 32)
                configSpace.setBarValue(at: barIndex + 1, value: highMask)
            }
        } else {
            // Guest is programming the BAR base address.
            switch barInfo.type {
            case .memory32:
                let addr = value & 0xFFFF_FFF0
                configSpace.setBarValue(at: barIndex, value: addr | (barInfo.prefetchable ? 0x08 : 0x00))
            case .memory64:
                let addr = value & 0xFFFF_FFF0
                configSpace.setBarValue(at: barIndex, value: addr | 0x04 | (barInfo.prefetchable ? 0x08 : 0x00))
            case .io:
                let addr = value & 0xFFFF_FFFC
                configSpace.setBarValue(at: barIndex, value: addr | 0x01)
            case .memory64High:
                // Guest writing the upper 32 bits of a 64-bit BAR.
                configSpace.setBarValue(at: barIndex, value: value)
            case .unused:
                break
            }
        }
    }
}

// MARK: - PCI Errors

/// Errors related to PCI device operations.
public enum PCIError: Error, CustomStringConvertible {
    /// The requested PCI slot is already occupied.
    case slotOccupied(slot: Int, function: Int)
    /// PCI bus capacity exceeded (max 32 devices x 8 functions).
    case busCapacityExceeded
    /// MMIO address allocation failed.
    case mmioAllocationFailed(size: UInt64, alignment: UInt64)
    /// Invalid BAR index.
    case invalidBAR(index: Int)
    /// Device not found at the given slot/function.
    case deviceNotFound(slot: Int, function: Int)

    public var description: String {
        switch self {
        case .slotOccupied(let slot, let function):
            return "PCI slot \(slot) function \(function) is already occupied"
        case .busCapacityExceeded:
            return "PCI bus capacity exceeded (max 32 devices x 8 functions)"
        case .mmioAllocationFailed(let size, let alignment):
            return "Failed to allocate \(size) bytes (alignment \(alignment)) of PCI MMIO space"
        case .invalidBAR(let index):
            return "Invalid BAR index: \(index)"
        case .deviceNotFound(let slot, let function):
            return "No PCI device at slot \(slot) function \(function)"
        }
    }
}
