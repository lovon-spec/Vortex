// VirtioTransport.swift — Virtio-PCI transport layer.
// VortexDevices
//
// Wraps a VirtioDeviceBase as a PCI device, conforming to the PCIDeviceEmulation
// protocol from VortexHV. Implements the Virtio 1.2 modern PCI transport (Section 4.1).
//
// PCI Identity:
//   Vendor ID:  0x1AF4 (Red Hat / Virtio)
//   Device ID:  0x1040 + device_type (modern virtio-pci)
//   Subsystem Vendor ID: 0x1AF4
//   Subsystem ID: device_type
//   Revision ID: 1 (non-transitional modern device)
//
// BAR Layout:
//   BAR0: Virtio capabilities (common cfg, notify, ISR, device cfg) — 32-bit memory
//   BAR4: MSI-X table and PBA — 32-bit memory
//
// PCI Capabilities (vendor-specific type 0x09 with virtio cfg_type):
//   1. Common Configuration:  BAR0, offset 0x000, size 0x038
//   2. Notification:          BAR0, offset 0x038, size varies (4 * numQueues)
//   3. ISR Status:            BAR0, offset after notify, size 0x004
//   4. Device Config:         BAR0, offset after ISR, size varies
//   5. MSI-X capability (PCI cap ID 0x11)
//
// MSI-X:
//   Table and PBA in BAR4.
//   Vectors 0..<numQueues: per-queue interrupts
//   Vector numQueues: configuration change
//
// Threading model: All BAR reads/writes come from the vCPU exit handler thread.
// The transport does not introduce any additional concurrency.

import Foundation
import VortexCore
import VortexHV

// MARK: - MSI-X Table Entry

/// An MSI-X table entry (16 bytes per the PCI spec).
struct MSIXTableEntry: Sendable {
    /// Message address (low 32 bits).
    var addressLow: UInt32 = 0
    /// Message address (high 32 bits).
    var addressHigh: UInt32 = 0
    /// Message data (the interrupt vector/INTID).
    var data: UInt32 = 0
    /// Vector control (bit 0 = masked).
    var control: UInt32 = 1 // Masked by default

    /// Whether this vector is masked.
    var isMasked: Bool { (control & 1) != 0 }

    /// The full 64-bit message address.
    var address: UInt64 { UInt64(addressHigh) << 32 | UInt64(addressLow) }
}

// MARK: - Virtio PCI BAR0 Layout

/// Describes the BAR0 layout for virtio-pci capabilities.
struct VirtioBar0Layout: Sendable {
    let commonCfgOffset: Int
    let commonCfgSize: Int
    let notifyOffset: Int
    let notifySize: Int
    let notifyOffMultiplier: UInt32
    let isrOffset: Int
    let isrSize: Int
    let deviceCfgOffset: Int
    let deviceCfgSize: Int
    let totalSize: Int

    init(numQueues: Int, deviceCfgSize: Int) {
        // Common configuration structure.
        self.commonCfgOffset = 0
        self.commonCfgSize = VirtioCommonCfgOffset.structSize

        // Notification doorbells: one per queue, 4-byte stride.
        self.notifyOffset = VirtioCommonCfgOffset.structSize
        self.notifyOffMultiplier = 4
        self.notifySize = max(numQueues * 4, 4)

        // ISR status register (4 bytes, aligned).
        self.isrOffset = self.notifyOffset + self.notifySize
        self.isrSize = 4

        // Device-specific configuration.
        self.deviceCfgOffset = self.isrOffset + self.isrSize
        self.deviceCfgSize = max(deviceCfgSize, 4)

        // Total BAR0 size, rounded up to next power of 2 for PCI BAR sizing.
        let raw = self.deviceCfgOffset + self.deviceCfgSize
        self.totalSize = VirtioBar0Layout.nextPowerOf2(max(raw, 256))
    }

    private static func nextPowerOf2(_ value: Int) -> Int {
        var v = value - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        return v + 1
    }
}

// MARK: - VirtioTransport

/// Virtio-PCI transport: wraps a VirtioDeviceBase as a PCI device.
///
/// Conforms to `PCIDeviceEmulation` (from VortexHV) so it can be added to the
/// PCI bus. The PCIBus handles ECAM config space dispatch and BAR MMIO routing;
/// this class overrides the relevant methods to implement virtio-pci semantics
/// on top of the standard PCI config space infrastructure.
///
/// ## Usage
///
/// ```swift
/// let blockDevice = VirtioBlockDevice(...)
/// let transport = VirtioTransport(device: blockDevice, msiController: msi)
/// transport.attachGuestMemory(memoryAccessor)
/// try pciBus.addDevice(transport)
/// ```
public final class VirtioTransport: PCIDeviceEmulation, @unchecked Sendable {

    // MARK: - PCIDeviceEmulation Requirements

    /// PCI configuration space (standard 256-byte Type 0 header).
    /// Populated at init with the device's identity fields and capabilities.
    public var configSpace: PCIConfigSpace

    /// BAR descriptors. BAR0 = virtio caps, BAR4 = MSI-X.
    public var bars: [BARInfo]

    // MARK: - Internal State

    /// The wrapped virtio device.
    public let device: VirtioDeviceBase

    /// MSI controller for interrupt delivery.
    private let msiController: MSIController?

    /// BAR0 layout computed from device parameters.
    private let bar0Layout: VirtioBar0Layout

    /// MSI-X table entries. Index 0..<numQueues for queues, last for config change.
    private var msixTable: [MSIXTableEntry]

    /// MSI-X Pending Bit Array (1 bit per vector, packed into UInt64s).
    private var msixPBA: [UInt64]

    /// Total number of MSI-X vectors (numQueues + 1 for config).
    private let msixVectorCount: Int

    /// MSI-X function mask (global mask bit from MSI-X Message Control).
    private var msixFunctionMask: Bool = false

    /// MSI-X enable bit.
    private var msixEnabled: Bool = false

    /// Allocated MSI SPI INTIDs from the MSI controller.
    private var allocatedSPIs: [UInt32] = []

    /// PCI capabilities data blob (built once at init, appended to config space).
    private let capabilitiesData: [UInt8]

    /// Offset of the first PCI capability in config space.
    private let capabilitiesOffset: Int = 0x40

    /// Size of BAR4 (MSI-X table + PBA).
    private let bar4Size: Int

    /// Byte offset within capabilities data where the MSI-X capability begins.
    private let msixCapDataOffset: Int

    // MARK: - Initialization

    /// Create a Virtio-PCI transport for a device.
    ///
    /// - Parameters:
    ///   - device: The virtio device to wrap.
    ///   - msiController: The MSI controller for interrupt routing (optional;
    ///     if nil, interrupts use ISR status + INTx fallback).
    public init(device: VirtioDeviceBase, msiController: MSIController? = nil) {
        self.device = device
        self.msiController = msiController

        // Compute PCI device ID: 0x1040 + device type ID (modern virtio-pci).
        let pciDeviceID: UInt16 = 0x1040 + device.deviceType.typeID

        // Compute BAR0 layout.
        let layout = VirtioBar0Layout(
            numQueues: device.numQueues,
            deviceCfgSize: device.deviceConfigSize
        )
        self.bar0Layout = layout

        // MSI-X: one vector per queue + one for config change.
        self.msixVectorCount = device.numQueues + 1
        self.msixTable = Array(repeating: MSIXTableEntry(), count: device.numQueues + 1)
        let pbaQwords = (device.numQueues + 1 + 63) / 64
        self.msixPBA = Array(repeating: 0, count: pbaQwords)

        // BAR4 size: MSI-X table (16 bytes/entry) + PBA (8 bytes per 64 vectors).
        let tableBytes = (device.numQueues + 1) * 16
        let pbaBytes = pbaQwords * 8
        self.bar4Size = VirtioTransport.nextPowerOf2(max(tableBytes + pbaBytes, 256))

        // Build PCI capabilities chain blob and record MSI-X offset within it.
        let (capsData, msixOff) = VirtioTransport.buildCapabilities(
            bar0Layout: layout,
            msixVectorCount: device.numQueues + 1
        )
        self.capabilitiesData = capsData
        self.msixCapDataOffset = msixOff

        // Compute class code components from device type.
        let (classCodeByte, subclass, progIF) = VirtioTransport.classCodeComponents(device.deviceType)

        // Build PCIConfigSpace with the device's identity.
        self.configSpace = PCIConfigSpace(
            vendorID: PCIVendorID.redHat,
            deviceID: pciDeviceID,
            revisionID: 1,
            classCode: classCodeByte,
            subclass: subclass,
            progIF: progIF,
            subsystemVendorID: PCIVendorID.redHat,
            subsystemID: device.deviceType.typeID,
            interruptPin: 0x01,
            headerType: 0x00
        )

        // Point capabilities pointer to our data.
        configSpace.capabilitiesPointer = UInt8(capabilitiesOffset)

        // Write capabilities data into config space (starting at capabilitiesOffset).
        for (i, byte) in capsData.enumerated() {
            let offset = capabilitiesOffset + i
            if offset < 256 {
                configSpace.write8(at: offset, value: byte)
            }
        }

        // Build BAR descriptors.
        // BAR0: 32-bit memory BAR for virtio capabilities.
        // BARs 1-3: unused.
        // BAR4: 32-bit memory BAR for MSI-X table + PBA.
        // BAR5: unused.
        var barArray: [BARInfo] = []
        barArray.append(BARInfo(index: 0, type: .memory32, size: UInt64(layout.totalSize)))
        barArray.append(BARInfo(index: 1, type: .unused, size: 0))
        barArray.append(BARInfo(index: 2, type: .unused, size: 0))
        barArray.append(BARInfo(index: 3, type: .unused, size: 0))
        barArray.append(BARInfo(index: 4, type: .memory32, size: UInt64(bar4Size)))
        barArray.append(BARInfo(index: 5, type: .unused, size: 0))
        self.bars = barArray

        // Wire up interrupt delivery from device to transport.
        device.interruptHandler = { [weak self] queueIndex, msixVector in
            self?.deliverInterrupt(queueIndex: queueIndex, msixVector: msixVector)
        }
    }

    /// Attach guest memory to the underlying device (creates virtqueues).
    public func attachGuestMemory(_ memory: any GuestMemoryAccessor) {
        device.attachGuestMemory(memory)
    }

    // MARK: - Config Space Overrides

    /// Override config space reads to handle virtio capabilities and MSI-X dynamic state.
    ///
    /// For standard header fields, delegates to the default PCIConfigSpace read.
    /// For the capabilities region (offset >= 0x40), returns data from our built
    /// capabilities blob, with MSI-X Message Control reflecting live enable/mask state.
    public func readConfig(offset: Int, size: Int) -> UInt32 {
        // Check if this is reading the MSI-X Message Control register.
        let msixMCOffset = capabilitiesOffset + msixCapDataOffset + 2
        if offset == msixMCOffset && size == 2 {
            return UInt32(readMSIXMessageControl())
        }
        // For a 4-byte read that spans the MSI-X cap header and Message Control.
        if offset == capabilitiesOffset + msixCapDataOffset && size == 4 {
            let capIDAndNext = UInt32(configSpace.read16(at: offset))
            let mc = UInt32(readMSIXMessageControl()) << 16
            return capIDAndNext | mc
        }

        // Default: read from the static config space.
        switch size {
        case 1:  return UInt32(configSpace.read8(at: offset))
        case 2:  return UInt32(configSpace.read16(at: offset))
        case 4:  return configSpace.read32(at: offset)
        default: return 0xFFFF_FFFF
        }
    }

    /// Override config space writes to handle MSI-X Message Control.
    ///
    /// For standard header fields, delegates to the default write handler (which
    /// handles BAR sizing, read-only masking, etc.). Intercepts MSI-X Message Control
    /// writes to update enable/mask state.
    public func writeConfig(offset: Int, size: Int, value: UInt32) {
        let msixMCOffset = capabilitiesOffset + msixCapDataOffset + 2

        if offset == msixMCOffset && size >= 2 {
            writeMSIXMessageControl(UInt16(truncatingIfNeeded: value))
            return
        }

        // For standard offsets, use the default protocol implementation logic.
        // We inline the essential parts here since we can't call the default impl directly.
        switch offset {
        case PCIConfigOffset.vendorID, PCIConfigOffset.deviceID,
             PCIConfigOffset.revisionID, PCIConfigOffset.progIF,
             PCIConfigOffset.subclass, PCIConfigOffset.classCode,
             PCIConfigOffset.headerType, PCIConfigOffset.subsystemVendorID,
             PCIConfigOffset.subsystemID, PCIConfigOffset.capabilitiesPointer:
            // Read-only fields — ignore writes.
            return

        case PCIConfigOffset.status:
            // Write-1-to-clear for error bits (bits 15:11).
            let current = configSpace.status
            let w1cMask: UInt16 = 0xF800
            let clearedBits = UInt16(truncatingIfNeeded: value) & w1cMask
            configSpace.status = current & ~clearedBits
            return

        case PCIConfigOffset.bar0, PCIConfigOffset.bar1, PCIConfigOffset.bar2,
             PCIConfigOffset.bar3, PCIConfigOffset.bar4, PCIConfigOffset.bar5:
            // BAR writes are handled by the default protocol extension's handleBARWrite.
            // However, we don't have access to the default impl, so we perform the
            // write to configSpace and let the PCIBus allocator handle sizing.
            let barIndex = (offset - PCIConfigOffset.bar0) / 4
            if barIndex < bars.count && bars[barIndex].type != .unused {
                let barInfo = bars[barIndex]
                if value == 0xFFFF_FFFF {
                    // BAR sizing probe.
                    let sizeMask = ~(UInt32(truncatingIfNeeded: barInfo.size) - 1) & 0xFFFF_FFF0
                    configSpace.setBarValue(at: barIndex, value: sizeMask)
                } else {
                    configSpace.setBarValue(at: barIndex, value: value & 0xFFFF_FFF0)
                }
            }
            return

        default:
            break
        }

        // For other offsets (command, interrupt line, etc.), write directly.
        switch size {
        case 1:  configSpace.write8(at: offset, value: UInt8(truncatingIfNeeded: value))
        case 2:  configSpace.write16(at: offset, value: UInt16(truncatingIfNeeded: value))
        case 4:  configSpace.write32(at: offset, value: value)
        default: break
        }
    }

    // MARK: - BAR MMIO Access

    /// Read from a BAR MMIO region.
    ///
    /// BAR0 contains the virtio common config, notification, ISR, and device config regions.
    /// BAR4 contains the MSI-X table and PBA.
    public func readBAR(bar: Int, offset: UInt64, size: Int) -> UInt64 {
        let off = Int(offset)
        switch bar {
        case 0:
            return readBar0(offset: off, size: size)
        case 4:
            return readBar4MSIX(offset: off, size: size)
        default:
            return 0
        }
    }

    /// Write to a BAR MMIO region.
    public func writeBAR(bar: Int, offset: UInt64, size: Int, value: UInt64) {
        let off = Int(offset)
        switch bar {
        case 0:
            writeBar0(offset: off, size: size, value: value)
        case 4:
            writeBar4MSIX(offset: off, size: size, value: value)
        default:
            break
        }
    }

    /// Called by PCIBus after BAR addresses are allocated. No-op for virtio transport.
    public func didAllocateBARs() {
        // Nothing to do — virtio caps already encode BAR-relative offsets.
    }

    // MARK: - BAR0 Dispatch (Virtio Regions)

    private func readBar0(offset: Int, size: Int) -> UInt64 {
        let layout = bar0Layout

        if offset >= layout.commonCfgOffset && offset < layout.commonCfgOffset + layout.commonCfgSize {
            let reg = offset - layout.commonCfgOffset
            return UInt64(device.readCommonConfig(offset: reg, size: size))
        }

        if offset >= layout.notifyOffset && offset < layout.notifyOffset + layout.notifySize {
            // Notification registers are write-only doorbells. Reads return 0.
            return 0
        }

        if offset >= layout.isrOffset && offset < layout.isrOffset + layout.isrSize {
            return UInt64(device.readAndClearISR())
        }

        if offset >= layout.deviceCfgOffset && offset < layout.deviceCfgOffset + layout.deviceCfgSize {
            let reg = offset - layout.deviceCfgOffset
            return UInt64(device.readDeviceConfig(offset: reg, size: size))
        }

        return 0
    }

    private func writeBar0(offset: Int, size: Int, value: UInt64) {
        let layout = bar0Layout

        if offset >= layout.commonCfgOffset && offset < layout.commonCfgOffset + layout.commonCfgSize {
            let reg = offset - layout.commonCfgOffset
            device.writeCommonConfig(offset: reg, size: size, value: UInt32(truncatingIfNeeded: value))
            return
        }

        if offset >= layout.notifyOffset && offset < layout.notifyOffset + layout.notifySize {
            let queueIndex = (offset - layout.notifyOffset) / Int(layout.notifyOffMultiplier)
            device.processNotification(queueIndex: queueIndex)
            return
        }

        if offset >= layout.isrOffset && offset < layout.isrOffset + layout.isrSize {
            return  // ISR is read-only from the device side.
        }

        if offset >= layout.deviceCfgOffset && offset < layout.deviceCfgOffset + layout.deviceCfgSize {
            let reg = offset - layout.deviceCfgOffset
            device.writeDeviceConfig(offset: reg, size: size, value: UInt32(truncatingIfNeeded: value))
            return
        }
    }

    // MARK: - BAR4 MSI-X Table and PBA

    private func readBar4MSIX(offset: Int, size: Int) -> UInt64 {
        let tableEnd = msixVectorCount * 16

        if offset < tableEnd {
            let entryIndex = offset / 16
            let entryOffset = offset % 16
            guard entryIndex < msixTable.count else { return 0 }
            let entry = msixTable[entryIndex]

            switch entryOffset {
            case 0:  return UInt64(entry.addressLow)
            case 4:  return UInt64(entry.addressHigh)
            case 8:  return UInt64(entry.data)
            case 12: return UInt64(entry.control)
            default: return 0
            }
        } else {
            // PBA read.
            let pbaOffset = offset - tableEnd
            let qwordIndex = pbaOffset / 8
            guard qwordIndex < msixPBA.count else { return 0 }
            if size == 4 {
                let wordOffset = (pbaOffset % 8) / 4
                if wordOffset == 0 {
                    return UInt64(UInt32(truncatingIfNeeded: msixPBA[qwordIndex]))
                } else {
                    return UInt64(UInt32(truncatingIfNeeded: msixPBA[qwordIndex] >> 32))
                }
            }
            return msixPBA[qwordIndex]
        }
    }

    private func writeBar4MSIX(offset: Int, size: Int, value: UInt64) {
        let tableEnd = msixVectorCount * 16

        if offset < tableEnd {
            let entryIndex = offset / 16
            let entryOffset = offset % 16
            guard entryIndex < msixTable.count else { return }

            let val32 = UInt32(truncatingIfNeeded: value)
            switch entryOffset {
            case 0:  msixTable[entryIndex].addressLow = val32
            case 4:  msixTable[entryIndex].addressHigh = val32
            case 8:  msixTable[entryIndex].data = val32
            case 12:
                let wasMasked = msixTable[entryIndex].isMasked
                msixTable[entryIndex].control = val32
                if wasMasked && !msixTable[entryIndex].isMasked {
                    deliverPendingMSIX(vector: entryIndex)
                }
            default: break
            }
        }
        // PBA is read-only from the guest side.
    }

    // MARK: - Interrupt Delivery

    /// Deliver an interrupt from the virtio device to the guest.
    private func deliverInterrupt(queueIndex: Int, msixVector: UInt16) {
        guard msixEnabled else {
            // Legacy INTx path: ISR status is already set by the device.
            // The PCI host bridge / GIC will pick it up via the interrupt pin.
            return
        }

        guard msixVector != 0xFFFF else { return }
        let vectorIndex = Int(msixVector)
        guard vectorIndex < msixTable.count else { return }

        if msixFunctionMask || msixTable[vectorIndex].isMasked {
            setPendingBit(vector: vectorIndex)
        } else {
            fireMSIX(vector: vectorIndex)
        }
    }

    private func fireMSIX(vector: Int) {
        guard let msi = msiController else { return }
        guard vector < msixTable.count else { return }
        let entry = msixTable[vector]
        msi.mmioWrite(offset: 0x000, size: 4, value: UInt64(entry.data))
    }

    private func deliverPendingMSIX(vector: Int) {
        let qwordIndex = vector / 64
        let bitIndex = vector % 64
        guard qwordIndex < msixPBA.count else { return }

        if (msixPBA[qwordIndex] >> bitIndex) & 1 != 0 {
            msixPBA[qwordIndex] &= ~(1 << bitIndex)
            fireMSIX(vector: vector)
        }
    }

    private func setPendingBit(vector: Int) {
        let qwordIndex = vector / 64
        let bitIndex = vector % 64
        guard qwordIndex < msixPBA.count else { return }
        msixPBA[qwordIndex] |= (1 << bitIndex)
    }

    // MARK: - MSI-X Message Control

    /// Read the MSI-X Message Control register with live enable/mask state.
    private func readMSIXMessageControl() -> UInt16 {
        var mc = UInt16(msixVectorCount - 1) & 0x07FF
        if msixFunctionMask { mc |= (1 << 14) }
        if msixEnabled { mc |= (1 << 15) }
        return mc
    }

    /// Write the MSI-X Message Control register (enable, function mask).
    private func writeMSIXMessageControl(_ value: UInt16) {
        let wasEnabled = msixEnabled
        msixEnabled = (value & (1 << 15)) != 0
        msixFunctionMask = (value & (1 << 14)) != 0

        if msixEnabled && !wasEnabled {
            allocateMSIXVectors()
        }

        if !msixFunctionMask {
            for i in 0..<msixVectorCount {
                if !msixTable[i].isMasked {
                    deliverPendingMSIX(vector: i)
                }
            }
        }
    }

    /// Pre-allocate MSI SPI INTIDs when MSI-X is first enabled.
    private func allocateMSIXVectors() {
        guard let msi = msiController else { return }
        for spi in allocatedSPIs { msi.freeVector(spi) }
        allocatedSPIs.removeAll()

        for i in 0..<msixVectorCount {
            if let intid = msi.allocateVector() {
                allocatedSPIs.append(intid)
                msixTable[i].data = intid
                msixTable[i].addressLow = UInt32(truncatingIfNeeded: msi.doorbellAddress)
                msixTable[i].addressHigh = UInt32(truncatingIfNeeded: msi.doorbellAddress >> 32)
            }
        }
    }

    // MARK: - Static Helpers

    /// Determine PCI class code components from virtio device type.
    ///
    /// Returns (classCode, subclass, progIF) per the PCI Code and ID Assignment Spec.
    private static func classCodeComponents(_ type: VirtioDeviceType) -> (UInt8, UInt8, UInt8) {
        switch type {
        case .network:    return (0x02, 0x00, 0x00)  // Network controller
        case .block:      return (0x01, 0x00, 0x00)  // Mass storage controller
        case .console:    return (0x07, 0x80, 0x00)  // Communication controller, other
        case .gpu:        return (0x03, 0x80, 0x00)  // Display controller, other
        case .sound:      return (0x04, 0x01, 0x00)  // Multimedia, audio device
        case .filesystem: return (0x01, 0x80, 0x00)  // Mass storage, other
        case .entropy:    return (0xFF, 0x00, 0x00)  // Unassigned class
        case .balloon:    return (0xFF, 0x00, 0x00)  // Unassigned class
        case .input:      return (0x09, 0x80, 0x00)  // Input device, other
        case .socket:     return (0x07, 0x80, 0x00)  // Communication controller, other
        }
    }

    /// Build the PCI capabilities chain data.
    ///
    /// Returns the raw byte array and the offset within it where the MSI-X capability starts.
    ///
    /// Layout:
    /// 1. Virtio Common Cfg (vendor-specific, 16 bytes)
    /// 2. Virtio Notification (vendor-specific, 20 bytes — includes notify_off_multiplier)
    /// 3. Virtio ISR (vendor-specific, 16 bytes)
    /// 4. Virtio Device Cfg (vendor-specific, 16 bytes)
    /// 5. MSI-X (12 bytes)
    private static func buildCapabilities(
        bar0Layout: VirtioBar0Layout,
        msixVectorCount: Int
    ) -> (data: [UInt8], msixOffset: Int) {
        var data: [UInt8] = []

        let commonCapSize = 16
        let notifyCapSize = 20
        let isrCapSize = 16
        let deviceCapSize = 16
        // MSI-X cap is always 12 bytes (built by buildMSIXCap).

        let base = 0x40  // capabilitiesOffset
        let commonCapOff = 0
        let notifyCapOff = commonCapOff + commonCapSize
        let isrCapOff = notifyCapOff + notifyCapSize
        let deviceCapOff = isrCapOff + isrCapSize
        let msixCapOff = deviceCapOff + deviceCapSize

        // 1. Common Configuration capability.
        data.append(contentsOf: buildVirtioVendorCap(
            nextPtr: UInt8(base + notifyCapOff),
            capLen: UInt8(commonCapSize),
            cfgType: .commonCfg,
            bar: 0,
            offset: UInt32(bar0Layout.commonCfgOffset),
            length: UInt32(bar0Layout.commonCfgSize)
        ))

        // 2. Notification capability (with multiplier).
        var notifyCap = buildVirtioVendorCap(
            nextPtr: UInt8(base + isrCapOff),
            capLen: UInt8(notifyCapSize),
            cfgType: .notifyCfg,
            bar: 0,
            offset: UInt32(bar0Layout.notifyOffset),
            length: UInt32(bar0Layout.notifySize)
        )
        var multiplier = bar0Layout.notifyOffMultiplier.littleEndian
        withUnsafeBytes(of: &multiplier) { notifyCap.append(contentsOf: $0) }
        data.append(contentsOf: notifyCap)

        // 3. ISR Status capability.
        data.append(contentsOf: buildVirtioVendorCap(
            nextPtr: UInt8(base + deviceCapOff),
            capLen: UInt8(isrCapSize),
            cfgType: .isrCfg,
            bar: 0,
            offset: UInt32(bar0Layout.isrOffset),
            length: UInt32(bar0Layout.isrSize)
        ))

        // 4. Device-specific Configuration capability.
        data.append(contentsOf: buildVirtioVendorCap(
            nextPtr: UInt8(base + msixCapOff),
            capLen: UInt8(deviceCapSize),
            cfgType: .deviceCfg,
            bar: 0,
            offset: UInt32(bar0Layout.deviceCfgOffset),
            length: UInt32(bar0Layout.deviceCfgSize)
        ))

        // 5. MSI-X capability.
        data.append(contentsOf: buildMSIXCap(
            nextPtr: 0,
            tableSize: UInt16(msixVectorCount - 1),
            tableBIR: 4,
            tableOffset: 0,
            pbaBIR: 4,
            pbaOffset: UInt32(msixVectorCount * 16)
        ))

        return (data, msixCapOff)
    }

    /// Build a 16-byte virtio vendor-specific PCI capability.
    private static func buildVirtioVendorCap(
        nextPtr: UInt8,
        capLen: UInt8,
        cfgType: VirtioPCICapType,
        bar: UInt8,
        offset: UInt32,
        length: UInt32
    ) -> [UInt8] {
        var cap: [UInt8] = []
        cap.append(0x09)               // [0] cap_vndr = PCI_CAP_ID_VNDR
        cap.append(nextPtr)            // [1] cap_next
        cap.append(capLen)             // [2] cap_len
        cap.append(cfgType.rawValue)   // [3] cfg_type
        cap.append(bar)                // [4] bar
        cap.append(0)                  // [5] id (padding)
        cap.append(0)                  // [6] padding
        cap.append(0)                  // [7] padding

        var offsetLE = offset.littleEndian
        withUnsafeBytes(of: &offsetLE) { cap.append(contentsOf: $0) }

        var lengthLE = length.littleEndian
        withUnsafeBytes(of: &lengthLE) { cap.append(contentsOf: $0) }

        return cap
    }

    /// Build a 12-byte MSI-X PCI capability.
    private static func buildMSIXCap(
        nextPtr: UInt8,
        tableSize: UInt16,
        tableBIR: UInt8,
        tableOffset: UInt32,
        pbaBIR: UInt8,
        pbaOffset: UInt32
    ) -> [UInt8] {
        var cap: [UInt8] = []
        cap.append(0x11)               // [0] cap_id = PCI_CAP_ID_MSIX
        cap.append(nextPtr)            // [1] cap_next

        var mc = tableSize.littleEndian
        withUnsafeBytes(of: &mc) { cap.append(contentsOf: $0) }

        var tableOffsetBIR = (tableOffset & ~0x7) | UInt32(tableBIR & 0x7)
        tableOffsetBIR = tableOffsetBIR.littleEndian
        withUnsafeBytes(of: &tableOffsetBIR) { cap.append(contentsOf: $0) }

        var pbaOffsetBIR = (pbaOffset & ~0x7) | UInt32(pbaBIR & 0x7)
        pbaOffsetBIR = pbaOffsetBIR.littleEndian
        withUnsafeBytes(of: &pbaOffsetBIR) { cap.append(contentsOf: $0) }

        return cap
    }

    /// Round up to next power of 2.
    private static func nextPowerOf2(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        var v = value - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        return v + 1
    }
}
