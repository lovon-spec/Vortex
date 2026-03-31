// MacBootChain.swift -- macOS guest boot orchestrator.
// VortexBoot
//
// Coordinates the macOS guest boot sequence:
//   1. Load kernel cache from IPSW into guest RAM.
//   2. Build/patch a macOS-compatible device tree.
//   3. Load device tree into guest RAM.
//   4. Configure initial vCPU register state (PC, X0, CPSR).
//   5. Return BootParameters for the VMM to apply.
//
// This is the primary integration point between IPSW extraction, device
// tree construction, platform identity, and the VMM's memory/register
// setup. The exact boot approach (direct kernel load, firmware shim, or
// hybrid) is under active investigation -- this file provides a clear
// skeleton with extension points for each approach.

import Foundation
import VortexCore
import VortexHV

// MARK: - Boot Parameters

/// Parameters needed to start a macOS guest VM.
///
/// After `MacBootChain.prepareBoot()` finishes loading data into guest
/// memory, it returns this struct so the VMM can set the initial vCPU
/// register state and begin execution.
public struct BootParameters: Sendable {
    /// Guest physical address where the kernel entry point is loaded.
    public let kernelLoadAddress: UInt64

    /// Guest physical address of the kernel entry point.
    ///
    /// For Mach-O kernel caches this may differ from `kernelLoadAddress`
    /// if the entry point is at an offset within the loaded image.
    public let entryPoint: UInt64

    /// Guest physical address where the device tree blob is placed.
    public let deviceTreeAddress: UInt64

    /// Size of the device tree blob in bytes.
    public let deviceTreeSize: Int

    /// Boot arguments string passed to the kernel.
    public let bootArgs: String

    /// Initial value for the program counter (typically `entryPoint`).
    public let initialPC: UInt64

    /// Initial value for X0 (typically the device tree pointer).
    public let initialX0: UInt64

    /// Initial value for CPSR.
    ///
    /// For ARM64 guest boot this is typically `0x3C5` (EL1h with
    /// DAIF interrupts masked).
    public let initialCPSR: UInt64

    /// Size of the loaded kernel image in bytes.
    public let kernelSize: Int

    /// Optional: guest physical address of auxiliary data (ramdisk, etc.).
    public let auxiliaryDataAddress: UInt64?

    /// Optional: size of auxiliary data.
    public let auxiliaryDataSize: Int?

    public init(
        kernelLoadAddress: UInt64,
        entryPoint: UInt64,
        deviceTreeAddress: UInt64,
        deviceTreeSize: Int,
        bootArgs: String,
        initialPC: UInt64,
        initialX0: UInt64,
        initialCPSR: UInt64 = 0x3C5,
        kernelSize: Int = 0,
        auxiliaryDataAddress: UInt64? = nil,
        auxiliaryDataSize: Int? = nil
    ) {
        self.kernelLoadAddress = kernelLoadAddress
        self.entryPoint = entryPoint
        self.deviceTreeAddress = deviceTreeAddress
        self.deviceTreeSize = deviceTreeSize
        self.bootArgs = bootArgs
        self.initialPC = initialPC
        self.initialX0 = initialX0
        self.initialCPSR = initialCPSR
        self.kernelSize = kernelSize
        self.auxiliaryDataAddress = auxiliaryDataAddress
        self.auxiliaryDataSize = auxiliaryDataSize
    }
}

// MARK: - Mac Boot Chain

/// Orchestrates the macOS guest boot sequence.
///
/// This class is responsible for:
/// 1. Taking extracted IPSW contents and a VM reference.
/// 2. Loading the kernel cache into guest RAM.
/// 3. Building a macOS-compatible device tree.
/// 4. Loading the device tree into guest RAM.
/// 5. Returning `BootParameters` with entry point and register state.
///
/// ## Boot Approaches (under investigation)
///
/// **Approach A: Direct Kernel Load** (currently implemented skeleton)
/// - Load the kernel cache directly at the kernel load address.
/// - Build a device tree from scratch.
/// - Set PC to kernel entry, X0 to device tree.
/// - Pro: Simple, no firmware dependency.
/// - Con: XNU may require iBoot-provided state we cannot replicate.
///
/// **Approach B: Firmware Shim**
/// - Load a minimal firmware shim that sets up XNU's expected environment.
/// - The shim loads the kernel cache and device tree.
/// - Pro: Can handle iBoot handoff protocol.
/// - Con: Requires writing the shim.
///
/// **Approach C: IPSW Device Tree + Kernel**
/// - Extract the device tree from the IPSW and patch it.
/// - Use the IPSW's kernel cache as-is.
/// - Pro: Closest to real hardware boot.
/// - Con: Requires understanding Apple's device tree format deeply.
///
/// ## Usage
/// ```swift
/// let chain = MacBootChain()
/// let params = try chain.prepareBoot(ipsw: ipswContents, vm: virtualMachine)
/// // VM now has kernel + DTB loaded in guest RAM.
/// // Apply params.initialPC, params.initialX0, params.initialCPSR to vCPU.
/// ```
public final class MacBootChain: @unchecked Sendable {

    /// The device tree patcher for macOS VMs.
    private let deviceTreePatcher: DeviceTreePatcher

    /// Boot arguments to pass to XNU.
    private let bootArgs: String

    /// Platform identity for the VM.
    private let platformIdentity: MacPlatformIdentity?

    /// Guest physical address for kernel loading.
    ///
    /// macOS kernel caches on Apple Silicon typically load at a fixed
    /// virtual address. The physical load address depends on the VM's
    /// memory map. We use the standard kernel load address from
    /// `MachineMemoryMap`.
    private let kernelLoadAddress: UInt64

    /// Guest physical address for the device tree.
    private let deviceTreeAddress: UInt64

    // MARK: - Initialization

    /// Creates a new macOS boot chain orchestrator.
    ///
    /// - Parameters:
    ///   - bootArgs: Kernel command line arguments. Common options:
    ///     - `serial=3`: Enable serial output.
    ///     - `-v`: Verbose boot.
    ///     - `debug=0x14e`: Debug flags.
    ///   - platformIdentity: Platform identity for this VM.
    ///     Generate with `MacPlatformIdentity.generate()` for new VMs.
    ///   - kernelLoadAddress: Override for the kernel load address.
    ///   - deviceTreeAddress: Override for the device tree placement.
    public init(
        bootArgs: String = "serial=3 -v",
        platformIdentity: MacPlatformIdentity? = nil,
        kernelLoadAddress: UInt64 = MachineMemoryMap.kernelLoadAddress,
        deviceTreeAddress: UInt64 = MachineMemoryMap.dtbAddress
    ) {
        self.deviceTreePatcher = DeviceTreePatcher()
        self.bootArgs = bootArgs
        self.platformIdentity = platformIdentity
        self.kernelLoadAddress = kernelLoadAddress
        self.deviceTreeAddress = deviceTreeAddress
    }

    // MARK: - Boot Preparation

    /// Prepares the macOS boot sequence by loading components into guest RAM.
    ///
    /// This method:
    /// 1. Loads the kernel cache from the IPSW into guest memory.
    /// 2. Builds a macOS-compatible device tree.
    /// 3. Loads the device tree into guest memory.
    /// 4. Returns boot parameters for vCPU initialization.
    ///
    /// The caller is responsible for applying the returned `BootParameters`
    /// to the primary vCPU's register state before starting execution.
    ///
    /// - Parameters:
    ///   - ipsw: Extracted IPSW contents (from `IPSWExtractor.extract`).
    ///   - vm: The virtual machine to load components into.
    /// - Returns: Boot parameters for vCPU initialization.
    /// - Throws: `VortexError.bootFailed` if required components are missing
    ///   or cannot be loaded.
    public func prepareBoot(
        ipsw: IPSWContents,
        vm: VirtualMachine
    ) throws -> BootParameters {
        // Step 1: Load kernel cache.
        let kernelSize = try loadKernelCache(from: ipsw, into: vm)

        // Step 2: Determine entry point.
        let entryPoint = try resolveEntryPoint(from: ipsw)

        // Step 3: Build and load device tree.
        let dtbSize = try loadDeviceTree(
            for: vm.config,
            into: vm,
            existingDTB: loadExistingDeviceTree(from: ipsw)
        )

        // Step 4: Assemble boot parameters.
        return BootParameters(
            kernelLoadAddress: kernelLoadAddress,
            entryPoint: entryPoint,
            deviceTreeAddress: deviceTreeAddress,
            deviceTreeSize: dtbSize,
            bootArgs: bootArgs,
            initialPC: entryPoint,
            initialX0: deviceTreeAddress,
            initialCPSR: 0x3C5,  // EL1h, DAIF masked.
            kernelSize: kernelSize
        )
    }

    /// Prepares boot with explicit parameters (no IPSW required).
    ///
    /// Use this when the kernel and device tree are supplied directly
    /// rather than extracted from an IPSW. Useful for development and
    /// testing with custom kernels.
    ///
    /// - Parameters:
    ///   - kernelURL: Path to the kernel cache file.
    ///   - deviceTreeURL: Optional path to a device tree file.
    ///   - vm: The virtual machine to load components into.
    /// - Returns: Boot parameters for vCPU initialization.
    public func prepareBootDirect(
        kernelURL: URL,
        deviceTreeURL: URL? = nil,
        vm: VirtualMachine
    ) throws -> BootParameters {
        // Load kernel.
        let kernelData = try Data(contentsOf: kernelURL)
        guard !kernelData.isEmpty else {
            throw VortexError.bootFailed(
                reason: "Kernel cache at \(kernelURL.path) is empty"
            )
        }
        vm.loadData(kernelData, at: kernelLoadAddress)

        // Determine entry point from kernel Mach-O header.
        let entryPoint = resolveEntryPointFromMachO(kernelData) ?? kernelLoadAddress

        // Build/load device tree.
        let existingDTB: Data? = if let dtURL = deviceTreeURL {
            try Data(contentsOf: dtURL)
        } else {
            nil
        }

        let dtbSize = try loadDeviceTree(
            for: vm.config,
            into: vm,
            existingDTB: existingDTB
        )

        return BootParameters(
            kernelLoadAddress: kernelLoadAddress,
            entryPoint: entryPoint,
            deviceTreeAddress: deviceTreeAddress,
            deviceTreeSize: dtbSize,
            bootArgs: bootArgs,
            initialPC: entryPoint,
            initialX0: deviceTreeAddress,
            initialCPSR: 0x3C5,
            kernelSize: kernelData.count
        )
    }

    // MARK: - Component Loading

    /// Loads the kernel cache from the IPSW into guest RAM.
    ///
    /// - Returns: Size of the loaded kernel in bytes.
    private func loadKernelCache(
        from ipsw: IPSWContents,
        into vm: VirtualMachine
    ) throws -> Int {
        guard let kernelURL = ipsw.kernelCache else {
            throw VortexError.bootFailed(
                reason: "No kernel cache found in IPSW at \(ipsw.extractionDirectory.path)"
            )
        }

        let kernelData = try Data(contentsOf: kernelURL)
        guard !kernelData.isEmpty else {
            throw VortexError.bootFailed(
                reason: "Kernel cache at \(kernelURL.path) is empty"
            )
        }

        // Validate that this looks like a Mach-O or img4 kernel.
        try validateKernelFormat(kernelData, at: kernelURL)

        // Load into guest RAM at the kernel load address.
        vm.loadData(kernelData, at: kernelLoadAddress)

        return kernelData.count
    }

    /// Resolves the kernel entry point from the IPSW kernel cache.
    ///
    /// For Mach-O kernel caches, the entry point is specified in the
    /// LC_UNIXTHREAD or LC_MAIN load command. For now, we use the
    /// load address itself as the entry point.
    private func resolveEntryPoint(from ipsw: IPSWContents) throws -> UInt64 {
        guard let kernelURL = ipsw.kernelCache else {
            return kernelLoadAddress
        }

        // Read the first few bytes to check for Mach-O.
        let headerData: Data
        do {
            let fileHandle = try FileHandle(forReadingFrom: kernelURL)
            defer { fileHandle.closeFile() }
            headerData = fileHandle.readData(ofLength: 4096)
        } catch {
            return kernelLoadAddress
        }

        return resolveEntryPointFromMachO(headerData) ?? kernelLoadAddress
    }

    /// Attempts to extract the entry point from a Mach-O header.
    ///
    /// The ARM64 Mach-O magic is 0xFEEDFACF. If found, we scan
    /// load commands for the entry point. This is a best-effort parser.
    ///
    /// - Parameter data: At least the first 4096 bytes of the kernel.
    /// - Returns: The entry point offset, or nil if not a Mach-O.
    private func resolveEntryPointFromMachO(_ data: Data) -> UInt64? {
        guard data.count >= 32 else { return nil }

        return data.withUnsafeBytes { buffer -> UInt64? in
            let magic = buffer.load(fromByteOffset: 0, as: UInt32.self)

            // ARM64 Mach-O magic (little-endian).
            let machO64Magic: UInt32 = 0xFEED_FACF

            guard magic == machO64Magic else { return nil }

            // Mach-O 64-bit header:
            //   magic (4), cputype (4), cpusubtype (4), filetype (4),
            //   ncmds (4), sizeofcmds (4), flags (4), reserved (4) = 32 bytes
            let ncmds = buffer.load(fromByteOffset: 16, as: UInt32.self)
            var offset = 32  // Past header.

            for _ in 0..<ncmds {
                guard offset + 8 <= data.count else { break }
                let cmd = buffer.load(fromByteOffset: offset, as: UInt32.self)
                let cmdsize = buffer.load(fromByteOffset: offset + 4, as: UInt32.self)

                // LC_UNIXTHREAD = 0x5
                if cmd == 0x5 {
                    // ARM64 thread state: flavor + count + registers
                    // The entry point is at register X[32] (PC) in the state.
                    // Flavor (4) + count (4) = 8 bytes past cmd header (8).
                    // ARM_THREAD_STATE64 registers: x0-x28, fp, lr, sp, pc
                    // PC is at index 32 (offset 32 * 8 = 256 bytes from start of state).
                    let pcOffset = offset + 16 + (32 * 8)
                    if pcOffset + 8 <= data.count {
                        let pc = buffer.load(fromByteOffset: pcOffset, as: UInt64.self)
                        if pc != 0 {
                            // The PC is a virtual address. For direct loading,
                            // compute the offset from the kernel base.
                            // For now, return the physical load address plus
                            // the offset from the virtual base.
                            // TODO: Proper VA-to-PA translation for kernel caches.
                            return kernelLoadAddress
                        }
                    }
                }

                offset += Int(cmdsize)
            }

            // No LC_UNIXTHREAD found; use load address as entry point.
            return kernelLoadAddress
        }
    }

    /// Loads the device tree for the macOS guest into guest RAM.
    ///
    /// If an existing device tree is provided (from IPSW), it will be
    /// patched. Otherwise, a new device tree is built from scratch.
    ///
    /// - Returns: Size of the device tree in bytes.
    private func loadDeviceTree(
        for vmConfig: VMConfig,
        into vm: VirtualMachine,
        existingDTB: Data?
    ) throws -> Int {
        let dtConfig = MacDeviceTreeConfig(
            cpuCount: vmConfig.cpuCount,
            memorySize: vmConfig.ramSize,
            bootArgs: bootArgs,
            platformIdentity: platformIdentity
        )

        let dtbData: Data
        if let existing = existingDTB {
            dtbData = deviceTreePatcher.patchDeviceTree(
                existingDTB: existing,
                config: dtConfig
            )
        } else {
            dtbData = deviceTreePatcher.buildMacOSDeviceTree(config: dtConfig)
        }

        guard !dtbData.isEmpty else {
            throw VortexError.bootFailed(reason: "Generated device tree is empty")
        }

        vm.loadData(dtbData, at: deviceTreeAddress)
        return dtbData.count
    }

    /// Attempts to load an existing device tree from the IPSW.
    private func loadExistingDeviceTree(from ipsw: IPSWContents) -> Data? {
        guard let dtURL = ipsw.deviceTree else { return nil }
        return try? Data(contentsOf: dtURL)
    }

    // MARK: - Validation

    /// Validates that the kernel data looks like a valid kernel image.
    ///
    /// Checks for recognized file format signatures:
    /// - Mach-O 64-bit: `0xFEEDFACF`
    /// - IMG4 container: `IM4P` tag
    /// - Compressed kernel: gzip or lzfse headers
    private func validateKernelFormat(
        _ data: Data,
        at url: URL
    ) throws {
        guard data.count >= 4 else {
            throw VortexError.invalidRestoreImage(
                path: url.path,
                reason: "Kernel cache file is too small (\(data.count) bytes)"
            )
        }

        let magic = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: 0, as: UInt32.self)
        }

        let validMagics: Set<UInt32> = [
            0xFEED_FACF,  // Mach-O 64-bit (little-endian).
            0xCFFA_EDFE,  // Mach-O 64-bit (big-endian, unlikely on ARM64).
            0x1F8B_0000,  // gzip (first two bytes, masked).
        ]

        // Check Mach-O magic.
        if validMagics.contains(magic) {
            return
        }

        // Check for IMG4 container ("IM4P" as ASCII).
        if data.count >= 16 {
            let im4pTag = String(data: data[8..<12], encoding: .ascii)
            if im4pTag == "IM4P" {
                return
            }

            // Also check for raw DER sequence tag at offset 0.
            if data[0] == 0x30 {
                // Likely a DER-encoded IMG4 or ASN.1 container.
                return
            }
        }

        // Check for Apple's bvx2 (lzfse) compression.
        if data.count >= 4 {
            let bvx2Magic = String(data: data[0..<4], encoding: .ascii)
            if bvx2Magic == "bvx2" || bvx2Magic == "bvx-" || bvx2Magic == "bvx1" {
                return
            }
        }

        // If we get here, warn but do not fail -- the format might be
        // one we do not yet recognize. Log and continue.
        // TODO: Upgrade to a hard error once all kernel formats are cataloged.
    }
}
