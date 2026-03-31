// MachineConfig.swift -- Memory map constants and IRQ assignments for the virtual platform.
// VortexHV

import Foundation

// MARK: - VM Configuration

/// User-facing configuration for creating a virtual machine.
public struct VMConfig: Sendable {
    /// Number of virtual CPUs.
    public var cpuCount: Int
    /// RAM size in bytes.
    public var ramSize: UInt64
    /// Kernel or firmware image path (optional -- caller may load manually).
    public var kernelPath: String?
    /// Initial ramdisk path (optional).
    public var initrdPath: String?
    /// Kernel boot arguments.
    public var bootArgs: String
    /// Guest OS type hint.
    public var guestOS: GuestOSHint

    public enum GuestOSHint: Sendable {
        case linux
        case macOS
        case generic
    }

    public init(
        cpuCount: Int = 1,
        ramSize: UInt64 = 512 * 1024 * 1024,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        bootArgs: String = "",
        guestOS: GuestOSHint = .linux
    ) {
        self.cpuCount = cpuCount
        self.ramSize = ramSize
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.bootArgs = bootArgs
        self.guestOS = guestOS
    }
}

// MARK: - Machine Memory Map

/// Fixed guest physical address layout for the virtual platform.
///
/// Layout (addresses grow downward):
/// ```
/// 0x0000_0000_0000 ..                           -- RAM base
/// 0x0000_4000_0000 .. (RAM base + ramSize)       -- RAM (default 1 GiB at 0x4000_0000)
/// 0x0800_0000                                    -- GIC Distributor
/// 0x080A_0000                                    -- GIC Redistributor base
/// 0x0900_0000                                    -- UART0 (PL011)
/// 0x0901_0000                                    -- RTC (PL031)
/// 0x0902_0000                                    -- fw_cfg device
/// 0x0C00_0000                                    -- GIC MSI frame
/// 0x1000_0000                                    -- PCI ECAM
/// 0x2000_0000                                    -- PCI MMIO (32-bit window)
/// 0x80_0000_0000                                 -- PCI MMIO (64-bit window)
/// ```
public enum MachineMemoryMap {
    // -- RAM ----------------------------------------------------------------
    /// Default guest RAM base address (1 GiB mark, leaving low memory for devices).
    public static let ramBase: UInt64 = 0x4000_0000

    // -- GIC ----------------------------------------------------------------
    /// GIC v3 Distributor base address.
    public static let gicDistributorBase: UInt64 = 0x0800_0000
    /// GIC v3 Redistributor base address.
    public static let gicRedistributorBase: UInt64 = 0x080A_0000
    /// GIC MSI frame base address.
    public static let gicMSIBase: UInt64 = 0x0C00_0000
    /// GIC Distributor region size.
    public static let gicDistributorSize: UInt64 = 0x0001_0000
    /// GIC Redistributor region size per CPU (two 64 KiB frames).
    public static let gicRedistributorPerCPUSize: UInt64 = 0x0002_0000

    // -- UART ---------------------------------------------------------------
    /// PL011 UART0 base address.
    public static let uart0Base: UInt64 = 0x0900_0000
    /// PL011 UART region size.
    public static let uart0Size: UInt64 = 0x0000_1000

    // -- RTC ----------------------------------------------------------------
    /// PL031 RTC base address.
    public static let rtcBase: UInt64 = 0x0901_0000
    /// PL031 RTC region size.
    public static let rtcSize: UInt64 = 0x0000_1000

    // -- fw_cfg -------------------------------------------------------------
    /// QEMU fw_cfg device base address.
    public static let fwCfgBase: UInt64 = 0x0902_0000
    /// fw_cfg region size.
    public static let fwCfgSize: UInt64 = 0x0000_1000

    // -- PCI ----------------------------------------------------------------
    /// PCI Express ECAM configuration space base.
    public static let pciEcamBase: UInt64 = 0x1000_0000
    /// PCI ECAM size (256 MiB covers 256 buses).
    public static let pciEcamSize: UInt64 = 0x1000_0000
    /// PCI MMIO 32-bit window base.
    public static let pciMmio32Base: UInt64 = 0x2000_0000
    /// PCI MMIO 32-bit window size.
    public static let pciMmio32Size: UInt64 = 0x2000_0000
    /// PCI MMIO 64-bit window base.
    public static let pciMmio64Base: UInt64 = 0x80_0000_0000
    /// PCI MMIO 64-bit window size.
    public static let pciMmio64Size: UInt64 = 0x80_0000_0000

    // -- DTB ----------------------------------------------------------------
    /// Default address to place the flattened device tree in RAM.
    /// Typically placed at RAM base + 64 MiB.
    public static let dtbAddress: UInt64 = ramBase + 0x0400_0000

    // -- Kernel / Initrd default locations ---------------------------------
    /// Default kernel load address.
    public static let kernelLoadAddress: UInt64 = ramBase + 0x0008_0000
    /// Default initrd load address (kernel + 64 MiB).
    public static let initrdLoadAddress: UInt64 = ramBase + 0x0800_0000
}

// MARK: - IRQ Assignments

/// SPI interrupt numbers for platform devices.
/// ARM GIC SPIs start at INTID 32. These are SPI offsets (add 32 for INTID).
public enum MachineIRQ {
    /// UART0 SPI number.
    public static let uart0: UInt32 = 33
    /// RTC SPI number.
    public static let rtc: UInt32 = 34
    /// fw_cfg SPI number.
    public static let fwCfg: UInt32 = 35
    /// Virtual timer PPI (INTID 27 per ARM spec).
    public static let vtimerPPI: UInt32 = 27
    /// Physical timer PPI (INTID 30 per ARM spec).
    public static let ptimerPPI: UInt32 = 30
    /// Base SPI for PCI INTx (4 lines: A, B, C, D).
    public static let pciIntxBase: UInt32 = 36
    /// Number of PCI INTx lines.
    public static let pciIntxCount: UInt32 = 4
    /// MSI SPI range start.
    public static let msiBase: UInt32 = 64
    /// Number of MSI SPIs.
    public static let msiCount: UInt32 = 64
}

// MARK: - Page Size

/// Host page size. On Apple Silicon this is 16 KiB.
public let kPageSize: UInt64 = UInt64(vm_page_size)

/// Align a value up to the host page boundary.
public func pageAlignUp(_ value: UInt64) -> UInt64 {
    let mask = kPageSize - 1
    return (value + mask) & ~mask
}
