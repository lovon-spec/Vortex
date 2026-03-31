// GICv3.swift -- ARM GICv3 interrupt controller wrapper.
// VortexHV
//
// On macOS 15+, Apple provides HV-assisted GIC emulation via hv_gic_create().
// On macOS 14, we fall back to software-emulated MMIO GIC (distributor + redistributor).

import Foundation
import Hypervisor

// MARK: - GIC v3 Controller

/// ARM GICv3 interrupt controller abstraction.
///
/// When running on macOS 15+ with Hypervisor.framework GIC support, this wraps
/// `hv_gic_create()` and related APIs. On older systems, it falls back to
/// MMIO-emulated GIC distributor and redistributor devices.
public final class GICv3Controller: @unchecked Sendable {
    /// Whether the HV-assisted GIC is available and was successfully created.
    public private(set) var hvGICAvailable: Bool = false

    /// Number of vCPUs this GIC serves.
    public let vcpuCount: Int

    /// Fallback MMIO emulation (used when HV GIC is not available).
    public private(set) var distributor: GICv3Distributor?
    public private(set) var redistributors: [GICv3Redistributor] = []

    /// MSI controller (works with both HV and emulated GIC).
    public private(set) var msiController: MSIController?

    /// The distributor base address in guest physical memory.
    public let distributorBase: UInt64
    /// The redistributor base address.
    public let redistributorBase: UInt64
    /// The MSI region base address.
    public let msiBase: UInt64

    public init(
        vcpuCount: Int,
        distributorBase: UInt64 = MachineMemoryMap.gicDistributorBase,
        redistributorBase: UInt64 = MachineMemoryMap.gicRedistributorBase,
        msiBase: UInt64 = MachineMemoryMap.gicMSIBase
    ) {
        self.vcpuCount = vcpuCount
        self.distributorBase = distributorBase
        self.redistributorBase = redistributorBase
        self.msiBase = msiBase
    }

    /// Initialize the GIC. Call after hv_vm_create() but before any hv_vcpu_create().
    public func initialize() throws {
        if tryCreateHVGIC() {
            hvGICAvailable = true
            // Create MSI controller backed by HV GIC.
            msiController = MSIController(
                baseAddress: msiBase,
                spiBase: MachineIRQ.msiBase,
                spiCount: MachineIRQ.msiCount,
                useHVGIC: true
            )
        } else {
            hvGICAvailable = false
            // Create software-emulated GIC components.
            let dist = GICv3Distributor(
                baseAddress: distributorBase,
                spiCount: 960 // Standard GICv3 max
            )
            self.distributor = dist

            for cpu in 0..<vcpuCount {
                let cpuBase = redistributorBase + UInt64(cpu) * MachineMemoryMap.gicRedistributorPerCPUSize
                let isLast = (cpu == vcpuCount - 1)
                let redist = GICv3Redistributor(
                    baseAddress: cpuBase,
                    cpuIndex: cpu,
                    isLast: isLast
                )
                redistributors.append(redist)
            }

            msiController = MSIController(
                baseAddress: msiBase,
                spiBase: MachineIRQ.msiBase,
                spiCount: MachineIRQ.msiCount,
                useHVGIC: false
            )
        }
    }

    /// Register GIC MMIO devices with the address space (only needed for emulated GIC).
    public func registerMMIODevices(with addressSpace: AddressSpace) throws {
        if !hvGICAvailable {
            if let dist = distributor {
                try addressSpace.registerDevice(dist)
            }
            for redist in redistributors {
                try addressSpace.registerDevice(redist)
            }
        }
        // MSI controller is always an MMIO device for PCI MSI writes.
        if let msi = msiController {
            try addressSpace.registerDevice(msi)
        }
    }

    /// Set an SPI interrupt line level.
    public func setSPI(intid: UInt32, level: Bool) {
        if hvGICAvailable {
            if #available(macOS 15.0, *) {
                _ = hv_gic_set_spi(intid, level)
            }
        } else {
            distributor?.setSPI(intid: intid, level: level)
        }
    }

    /// Send a Software Generated Interrupt (SGI).
    /// In the emulated path, this sets the SGI pending on the target redistributor.
    public func sendSGI(from sourceCPU: Int, to targetCPU: Int, intid: UInt32) {
        if hvGICAvailable {
            // HV GIC handles SGIs internally via ICC system register emulation.
            // The guest writes ICC_SGI1R_EL1 which the HV GIC intercepts.
            return
        }
        guard targetCPU < redistributors.count else { return }
        redistributors[targetCPU].setPendingSGI(intid: intid)
    }

    /// Inject a pending IRQ to a vCPU. Used by the emulated GIC path.
    public func injectIRQ(vcpu: hv_vcpu_t) {
        if hvGICAvailable {
            // HV GIC manages injection automatically.
            return
        }
        // In the emulated path, set the IRQ pending on the vCPU.
        _ = hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, true)
    }

    /// Clear the VTimer mask for a vCPU (call when the guest EOIs the timer interrupt).
    public func clearVTimerMask(vcpu: hv_vcpu_t) {
        _ = hv_vcpu_set_vtimer_mask(vcpu, false)
    }

    /// Reset the GIC state.
    public func reset() {
        if hvGICAvailable {
            if #available(macOS 15.0, *) {
                _ = hv_gic_reset()
            }
        } else {
            distributor?.reset()
            for redist in redistributors {
                redist.reset()
            }
        }
    }

    // MARK: - Private: HV GIC Creation

    private func tryCreateHVGIC() -> Bool {
        guard #available(macOS 15.0, *) else { return false }

        let config = hv_gic_config_create()

        var ret = hv_gic_config_set_distributor_base(config, distributorBase)
        guard ret == HV_SUCCESS else { return false }

        ret = hv_gic_config_set_redistributor_base(config, redistributorBase)
        guard ret == HV_SUCCESS else { return false }

        // Configure MSI support.
        ret = hv_gic_config_set_msi_region_base(config, msiBase)
        if ret == HV_SUCCESS {
            _ = hv_gic_config_set_msi_interrupt_range(
                config,
                MachineIRQ.msiBase,
                MachineIRQ.msiCount
            )
        }

        ret = hv_gic_create(config)
        return ret == HV_SUCCESS
    }
}
