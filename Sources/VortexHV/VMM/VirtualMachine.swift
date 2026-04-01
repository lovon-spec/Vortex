// VirtualMachine.swift -- Top-level VM object that owns all VMM components.
// VortexHV
//
// Orchestrates the lifecycle of a virtual machine:
//   1. Create the HV VM via hv_vm_create()
//   2. Optionally create an HV-assisted GIC
//   3. Map guest RAM, load firmware/kernel
//   4. Create vCPU threads
//   5. Run/pause/resume/stop

import Foundation
import Hypervisor
import VortexCore

// MARK: - Virtual Machine

/// Top-level virtual machine object.
///
/// Owns the memory manager, address space, interrupt controller, timer,
/// vCPU threads, and registered MMIO devices.
///
/// ```swift
/// let config = VMConfig(cpuCount: 4, ramSize: 1 * 1024 * 1024 * 1024)
/// let vm = try VirtualMachine(config: config)
/// try vm.loadKernel(from: kernelURL)
/// try vm.start()
/// // ...
/// try vm.stop()
/// ```
public final class VirtualMachine: @unchecked Sendable {
    /// The VM configuration.
    public let config: VMConfig

    /// Lifecycle state machine.
    public let lifecycle = VMLifecycle()

    /// Guest physical memory manager.
    public let memoryManager = MemoryManager()

    /// MMIO address space and device registry.
    public let addressSpace = AddressSpace()

    /// GIC v3 interrupt controller.
    public private(set) var gic: GICv3Controller!

    /// ARM generic timer.
    public private(set) var timer: ARMGenericTimer!

    /// fw_cfg device.
    public private(set) var fwCfg: FWCfgDevice!

    /// The vCPU threads.
    public private(set) var vcpuThreads: [VCPUThread] = []

    /// The shared exit handler.
    public private(set) var exitHandler: VCPUExitHandler!

    /// Host pointer to the start of guest RAM.
    public private(set) var ramHostPointer: UnsafeMutableRawPointer?

    /// Whether the HV VM has been created.
    private var vmCreated = false

    // MARK: - Initialization

    /// Create a new virtual machine.
    ///
    /// This calls `hv_vm_create(nil)` to create the hypervisor VM context,
    /// allocates and maps guest RAM, and initializes all platform devices.
    ///
    /// - Parameter config: The VM configuration.
    /// - Throws: If the hypervisor VM cannot be created.
    public init(config: VMConfig) throws {
        self.config = config

        // Create the HV VM.
        let ret = hv_vm_create(nil)
        guard ret == HV_SUCCESS else {
            throw VMError.hvVMCreateFailed(code: ret)
        }
        vmCreated = true

        // Initialize the GIC (must be before vCPU creation).
        gic = GICv3Controller(vcpuCount: config.cpuCount)
        try gic.initialize()

        // Map guest RAM.
        let ramPtr = try memoryManager.mapRAM(
            at: MachineMemoryMap.ramBase,
            size: config.ramSize
        )
        ramHostPointer = ramPtr

        // Create platform devices.
        fwCfg = FWCfgDevice()
        timer = ARMGenericTimer(gic: gic)

        // Set up the exit handler.
        exitHandler = VCPUExitHandler(addressSpace: addressSpace)
        configureExitHandler()

        // Register platform MMIO devices.
        try gic.registerMMIODevices(with: addressSpace)
        try addressSpace.registerDevice(fwCfg)

        // Create vCPU threads (but do not start them yet).
        for i in 0..<config.cpuCount {
            let thread = VCPUThread(index: i, exitHandler: exitHandler)
            configureVCPUThread(thread)
            vcpuThreads.append(thread)
        }
    }

    // MARK: - Device Registration

    /// Register an additional MMIO device with the VM.
    public func addDevice(_ device: any MMIODevice) throws {
        try addressSpace.registerDevice(device)
    }

    // MARK: - Memory Loading

    /// Load raw data into guest RAM at a given guest physical address.
    public func loadData(_ data: Data, at gpa: UInt64) {
        guard let hostPtr = memoryManager.hostPointer(for: gpa) else {
            VortexLog.hv.warning("No host mapping for GPA 0x\(String(gpa, radix: 16))")
            return
        }
        data.withUnsafeBytes { src in
            hostPtr.copyMemory(from: src.baseAddress!, byteCount: data.count)
        }
    }

    /// Load a file into guest RAM at a given guest physical address.
    public func loadFile(at url: URL, gpa: UInt64) throws {
        let data = try Data(contentsOf: url)
        loadData(data, at: gpa)
    }

    /// Build and load a device tree blob into guest memory.
    /// - Returns: The GPA where the DTB was placed and its size.
    @discardableResult
    public func loadDTB(
        bootArgs: String? = nil,
        at gpa: UInt64 = MachineMemoryMap.dtbAddress,
        initrdStart: UInt64? = nil,
        initrdEnd: UInt64? = nil
    ) -> (gpa: UInt64, size: Int) {
        let builder = DTBBuilder(
            cpuCount: config.cpuCount,
            ramBase: MachineMemoryMap.ramBase,
            ramSize: config.ramSize,
            bootArgs: bootArgs ?? config.bootArgs,
            initrdStart: initrdStart,
            initrdEnd: initrdEnd
        )
        let dtbData = builder.build()
        loadData(dtbData, at: gpa)
        return (gpa, dtbData.count)
    }

    /// Map read-only ROM data (firmware, DTB) at a given GPA.
    @discardableResult
    public func mapROM(at gpa: UInt64, data: Data) throws -> UnsafeMutableRawPointer {
        try memoryManager.mapROM(at: gpa, data: data)
    }

    // MARK: - Lifecycle

    /// Start all vCPU threads and begin guest execution.
    public func start() throws {
        try lifecycle.transitionToStarting()

        do {
            for thread in vcpuThreads {
                try thread.start()
            }
            try lifecycle.transitionToRunning()
        } catch {
            lifecycle.transitionToError(message: "Failed to start vCPUs: \(error)")
            throw error
        }
    }

    /// Stop all vCPU threads and destroy the VM.
    public func stop() throws {
        try lifecycle.transitionToStopping()

        // Cancel all vCPU threads.
        for thread in vcpuThreads {
            thread.cancel()
        }

        // Cancel all host timers.
        timer.cancelAllTimers()

        // Wait briefly for threads to exit.
        Thread.sleep(forTimeInterval: 0.1)

        // Clean up memory.
        memoryManager.cleanup()
        addressSpace.removeAll()

        // Destroy the HV VM.
        if vmCreated {
            _ = hv_vm_destroy()
            vmCreated = false
        }

        try lifecycle.transitionToStopped()
    }

    /// Pause all vCPUs.
    public func pause() throws {
        try lifecycle.transitionToPaused()
        for thread in vcpuThreads {
            thread.pause()
        }
    }

    /// Resume all vCPUs.
    public func resume() throws {
        try lifecycle.transitionToResumed()
        for thread in vcpuThreads {
            thread.resume()
        }
    }

    // MARK: - Destruction

    deinit {
        if vmCreated {
            for thread in vcpuThreads {
                thread.cancel()
            }
            timer?.cancelAllTimers()
            memoryManager.cleanup()
            _ = hv_vm_destroy()
        }
    }

    // MARK: - Private Configuration

    private func configureExitHandler() {
        // HVC/SMC handler for PSCI.
        exitHandler.onHypercall = { [weak self] vcpu, info in
            self?.handlePSCI(vcpu: vcpu, info: info) ?? false
        }

        // WFI/WFE handler.
        exitHandler.onWFx = { [weak self] vcpu, isWFE in
            guard self != nil else { return }
            if isWFE {
                // WFE: yield -- just return immediately and let the vCPU continue.
                return
            }
            // WFI: hint that the vCPU is idle. In a real VMM we would
            // block the thread until an interrupt is pending. For now,
            // yield to avoid spinning.
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func configureVCPUThread(_ thread: VCPUThread) {
        let cpuIndex = thread.index

        // Set initial register state when the vCPU is created.
        thread.onVCPUCreated = { vcpu in
            // Set MPIDR_EL1 for GIC affinity routing.
            let mpidr = UInt64(cpuIndex) // Aff0 = cpuIndex
            _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_MPIDR_EL1, mpidr)

            // Primary CPU (index 0) gets the boot configuration.
            if cpuIndex == 0 {
                // Set PC to kernel entry point.
                _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, MachineMemoryMap.kernelLoadAddress)

                // X0 = DTB address (Linux boot protocol).
                _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, MachineMemoryMap.dtbAddress)

                // Start in EL1h with interrupts masked.
                // CPSR: M[3:0]=0b0101 (EL1h), D=1, A=1, I=1, F=1
                let cpsr: UInt64 = 0x3C5
                _ = hv_vcpu_set_reg(vcpu, HV_REG_CPSR, cpsr)
            } else {
                // Secondary CPUs start in a WFI loop, waiting for PSCI CPU_ON.
                // Park them by setting PC to a tight WFI loop.
                // We will wake them via PSCI CPU_ON.
                _ = hv_vcpu_set_reg(vcpu, HV_REG_CPSR, UInt64(0x3C5))
            }
        }

        // VTimer handler.
        thread.onVTimerActivated = { [weak self] vcpu in
            self?.timer.handleVTimerActivated(vcpu: vcpu)
        }
    }

    // MARK: - PSCI Handler

    /// Handle PSCI calls (Power State Coordination Interface).
    /// PSCI function IDs follow the ARM PSCI v1.0 specification.
    private func handlePSCI(vcpu: hv_vcpu_t, info: HypercallInfo) -> Bool {
        var x0: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpu, HV_REG_X0, &x0)
        let functionID = UInt32(truncatingIfNeeded: x0)

        switch functionID {
        case 0x8400_0000: // PSCI_VERSION
            // Return PSCI v1.0
            _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, 0x0001_0000)
            advancePC(vcpu: vcpu)
            return true

        case 0xC400_0003, 0x8400_0003: // PSCI_CPU_ON (64-bit / 32-bit)
            var targetCPU: UInt64 = 0
            var entryPoint: UInt64 = 0
            var contextID: UInt64 = 0
            _ = hv_vcpu_get_reg(vcpu, HV_REG_X1, &targetCPU)
            _ = hv_vcpu_get_reg(vcpu, HV_REG_X2, &entryPoint)
            _ = hv_vcpu_get_reg(vcpu, HV_REG_X3, &contextID)

            let cpuIndex = Int(targetCPU & 0xFF) // Aff0 is the CPU index
            if cpuIndex < vcpuThreads.count {
                let targetThread = vcpuThreads[cpuIndex]
                targetThread.onVCPUCreated = { vcpu in
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, entryPoint)
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, contextID)
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3C5) // EL1h, IRQs masked

                    let mpidr = UInt64(cpuIndex)
                    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_MPIDR_EL1, mpidr)
                }
                // If the thread is not yet started, start it.
                // If it is parked, it will pick up the new onVCPUCreated.
                do {
                    try targetThread.start()
                } catch {
                    // CPU already started or error.
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, UInt64(bitPattern: -2)) // ALREADY_ON
                    advancePC(vcpu: vcpu)
                    return true
                }
                _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, 0) // SUCCESS
            } else {
                _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, UInt64(bitPattern: -1)) // NOT_SUPPORTED
            }
            advancePC(vcpu: vcpu)
            return true

        case 0x8400_0008: // PSCI_SYSTEM_OFF
            VortexLog.hv.info("PSCI SYSTEM_OFF requested")
            for thread in vcpuThreads {
                thread.cancel()
            }
            return false // Stop the vCPU run loop

        case 0x8400_0009: // PSCI_SYSTEM_RESET
            VortexLog.hv.info("PSCI SYSTEM_RESET requested")
            for thread in vcpuThreads {
                thread.cancel()
            }
            return false

        case 0x8400_0001: // PSCI_CPU_SUSPEND
            // Return SUCCESS and let the vCPU idle.
            _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, 0)
            advancePC(vcpu: vcpu)
            return true

        case 0x8400_0002: // PSCI_CPU_OFF
            // This vCPU should stop.
            _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, 0)
            return false // Exit the run loop for this vCPU

        case 0x8400_000A: // PSCI_FEATURES
            var featureFunctionID: UInt64 = 0
            _ = hv_vcpu_get_reg(vcpu, HV_REG_X1, &featureFunctionID)
            // We support all the basic PSCI functions.
            _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, 0) // Supported
            advancePC(vcpu: vcpu)
            return true

        default:
            // Unknown PSCI function. Return NOT_SUPPORTED.
            _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, UInt64(bitPattern: -1))
            advancePC(vcpu: vcpu)
            return true
        }
    }

    private func advancePC(vcpu: hv_vcpu_t) {
        var pc: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
        _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc &+ 4)
    }
}

// MARK: - Errors

public enum VMError: Error, CustomStringConvertible {
    case hvVMCreateFailed(code: hv_return_t)
    case alreadyRunning
    case notRunning

    public var description: String {
        switch self {
        case .hvVMCreateFailed(let code):
            return "hv_vm_create failed with error code \(code)"
        case .alreadyRunning:
            return "VM is already running"
        case .notRunning:
            return "VM is not running"
        }
    }
}
