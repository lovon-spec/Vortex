// VirtioMMIOTransport.swift -- VirtIO MMIO transport.
// VortexDevices

import Foundation
import VortexHV

/// VirtIO 1.2 MMIO transport for native Linux guests.
public final class VirtioMMIOTransport: MMIODevice, @unchecked Sendable {
    public let baseAddress: UInt64
    public let regionSize: UInt64

    public let device: VirtioDeviceBase

    /// Called when the device interrupt line changes.
    public var onInterruptStateChanged: ((Bool) -> Void)?

    private var deviceFeatureSelect: UInt32 = 0
    private var driverFeatureSelect: UInt32 = 0
    private var queueSelect: UInt32 = 0

    public init(
        device: VirtioDeviceBase,
        baseAddress: UInt64,
        regionSize: UInt64 = MachineMemoryMap.virtioMMIODeviceSize
    ) {
        self.device = device
        self.baseAddress = baseAddress
        self.regionSize = regionSize

        device.interruptHandler = { [weak self] _, _ in
            self?.onInterruptStateChanged?(true)
        }
    }

    public func attachGuestMemory(_ memory: any GuestMemoryAccessor) {
        device.attachGuestMemory(memory)
    }

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        switch offset {
        case 0x000:
            return 0x7472_6976 // "virt"
        case 0x004:
            return 2
        case 0x008:
            return UInt64(device.deviceType.typeID)
        case 0x00C:
            return 0x1D7E
        case 0x010:
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.deviceFeatureSelect,
                size: 4,
                value: deviceFeatureSelect
            )
            return UInt64(device.readCommonConfig(
                offset: VirtioCommonCfgOffset.deviceFeature,
                size: 4
            ))
        case 0x034:
            selectQueue()
            return UInt64(device.readCommonConfig(offset: VirtioCommonCfgOffset.queueSize, size: 4))
        case 0x044:
            selectQueue()
            return UInt64(device.readCommonConfig(offset: VirtioCommonCfgOffset.queueEnable, size: 4))
        case 0x060:
            return UInt64(device.readISRStatus())
        case 0x070:
            return UInt64(device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 4))
        case 0x0FC:
            return UInt64(device.readCommonConfig(offset: VirtioCommonCfgOffset.configGeneration, size: 4))
        case 0x100..<0x200:
            return UInt64(device.readDeviceConfig(offset: Int(offset - 0x100), size: size))
        default:
            return 0
        }
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        switch offset {
        case 0x014:
            deviceFeatureSelect = UInt32(truncatingIfNeeded: value)
        case 0x020:
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.driverFeature,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x024:
            driverFeatureSelect = UInt32(truncatingIfNeeded: value)
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.driverFeatureSelect,
                size: 4,
                value: driverFeatureSelect
            )
        case 0x030:
            queueSelect = UInt32(truncatingIfNeeded: value)
            selectQueue()
        case 0x038:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueSize,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x044:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueEnable,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x050:
            device.processNotification(queueIndex: Int(value))
        case 0x064:
            device.acknowledgeISR(mask: UInt8(truncatingIfNeeded: value))
            if device.readISRStatus() == 0 {
                onInterruptStateChanged?(false)
            }
        case 0x070:
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.deviceStatus,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x080:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueDescLow,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x084:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueDescHigh,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x090:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueAvailLow,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x094:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueAvailHigh,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x0A0:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueUsedLow,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x0A4:
            selectQueue()
            device.writeCommonConfig(
                offset: VirtioCommonCfgOffset.queueUsedHigh,
                size: 4,
                value: UInt32(truncatingIfNeeded: value)
            )
        case 0x100..<0x200:
            device.writeDeviceConfig(
                offset: Int(offset - 0x100),
                size: size,
                value: UInt32(truncatingIfNeeded: value)
            )
        default:
            break
        }
    }

    private func selectQueue() {
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.queueSelect,
            size: 4,
            value: queueSelect
        )
    }
}

