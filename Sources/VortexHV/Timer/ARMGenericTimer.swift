// ARMGenericTimer.swift -- ARM Generic Timer handling for virtual timer exits.
// VortexHV
//
// When the guest programs the virtual timer (CNTV_CTL_EL0 / CNTV_CVAL_EL0),
// Hypervisor.framework fires HV_EXIT_REASON_VTIMER_ACTIVATED when the timer
// expires. The VMM must then:
// 1. Inject the timer IRQ into the guest via the GIC.
// 2. Mask the VTimer (automatic on exit, unmasked when guest EOIs).
//
// If the guest sets a timer far in the future, the framework handles
// the wait internally. If the guest disables the timer, no exit occurs.

import Foundation
import Hypervisor

// MARK: - ARM Generic Timer

/// Manages the ARM virtual timer for a set of vCPUs.
///
/// For each vCPU, when `HV_EXIT_REASON_VTIMER_ACTIVATED` fires:
/// 1. Read CNTV_CTL_EL0 to confirm the timer is enabled and asserted.
/// 2. Inject the timer SPI (INTID 27) via the GIC.
/// 3. The VTimer mask is automatically set by the framework.
/// 4. When the guest EOIs the interrupt, the VMM calls `clearVTimerMask`
///    to re-enable VTimer exits.
public final class ARMGenericTimer: @unchecked Sendable {
    /// The GIC controller for interrupt injection.
    private weak var gic: GICv3Controller?

    /// The virtual timer PPI INTID.
    public let vtimerINTID: UInt32

    /// Per-vCPU host-side DispatchSource timers for scheduling future timer IRQs.
    private let lock = NSLock()
    private var hostTimers: [Int: DispatchSourceTimer] = [:]

    public init(gic: GICv3Controller, vtimerINTID: UInt32 = MachineIRQ.vtimerPPI) {
        self.gic = gic
        self.vtimerINTID = vtimerINTID
    }

    /// Handle a VTIMER_ACTIVATED exit for a vCPU.
    ///
    /// Call this from the vCPU run loop when `exit.reason == HV_EXIT_REASON_VTIMER_ACTIVATED`.
    /// The VTimer mask is automatically set by the framework after this exit.
    ///
    /// - Parameter vcpu: The vCPU that received the vtimer exit.
    public func handleVTimerActivated(vcpu: hv_vcpu_t) {
        // Read the timer control register to confirm the timer condition.
        var cntv_ctl: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_CNTV_CTL_EL0, &cntv_ctl)

        let enabled = (cntv_ctl & 0x1) != 0       // ENABLE bit
        let masked = (cntv_ctl & 0x2) != 0         // IMASK bit
        let condition = (cntv_ctl & 0x4) != 0       // ISTATUS bit

        guard enabled && condition && !masked else {
            // Timer is not actually firing -- this can happen if the guest
            // modified the timer between the exit and this handler.
            return
        }

        // Inject the virtual timer IRQ.
        guard let gic = gic else { return }

        if gic.hvGICAvailable {
            // With HV GIC, the framework manages timer interrupt injection.
            // We just need to set the IRQ pending on the vCPU.
            _ = hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, true)
        } else {
            // Emulated path: inject via direct vCPU pending interrupt.
            _ = hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, true)
        }
    }

    /// Called when the guest EOIs the virtual timer interrupt.
    /// Unmasks the VTimer so the framework can fire VTimer exits again.
    ///
    /// - Parameter vcpu: The vCPU to unmask.
    public func clearVTimerMask(vcpu: hv_vcpu_t) {
        _ = hv_vcpu_set_vtimer_mask(vcpu, false)
    }

    /// Schedule a host-side timer to fire a VTimer interrupt at a future time.
    ///
    /// This is used when the vCPU is idle (WFI) and we want to wake it up
    /// when the virtual timer expires. Not normally needed since the framework
    /// handles timer waits in `hv_vcpu_run`, but useful for paused vCPUs.
    ///
    /// - Parameters:
    ///   - vcpuIndex: Index of the vCPU.
    ///   - deadline: Host absolute time (mach_absolute_time units) when the timer fires.
    ///   - handler: Block to call when the timer fires.
    public func scheduleHostTimer(
        vcpuIndex: Int,
        deadline: UInt64,
        handler: @escaping () -> Void
    ) {
        cancelHostTimer(vcpuIndex: vcpuIndex)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))

        // Convert mach_absolute_time to DispatchTime.
        let dispatchDeadline = DispatchTime(uptimeNanoseconds: machToNanos(deadline))
        timer.schedule(deadline: dispatchDeadline)
        timer.setEventHandler {
            handler()
        }

        lock.lock()
        hostTimers[vcpuIndex] = timer
        lock.unlock()

        timer.resume()
    }

    /// Cancel a previously scheduled host timer for a vCPU.
    public func cancelHostTimer(vcpuIndex: Int) {
        lock.lock()
        let timer = hostTimers.removeValue(forKey: vcpuIndex)
        lock.unlock()
        timer?.cancel()
    }

    /// Cancel all host timers.
    public func cancelAllTimers() {
        lock.lock()
        let allTimers = hostTimers
        hostTimers.removeAll()
        lock.unlock()
        for (_, timer) in allTimers {
            timer.cancel()
        }
    }

    /// Read the virtual timer comparator value for a vCPU.
    public func getVTimerComparatorValue(vcpu: hv_vcpu_t) -> UInt64 {
        var cval: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_CNTV_CVAL_EL0, &cval)
        return cval
    }

    /// Read the virtual timer control register for a vCPU.
    public func getVTimerControl(vcpu: hv_vcpu_t) -> UInt64 {
        var ctl: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_CNTV_CTL_EL0, &ctl)
        return ctl
    }

    // MARK: - Private

    private func machToNanos(_ machTime: UInt64) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return machTime * UInt64(info.numer) / UInt64(info.denom)
    }
}
