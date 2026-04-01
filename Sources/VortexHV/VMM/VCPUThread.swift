// VCPUThread.swift -- Per-vCPU run loop on a dedicated thread.
// VortexHV

import Foundation
import Hypervisor
import VortexCore

// MARK: - VCPU Thread

/// Manages a single virtual CPU on a dedicated pthread.
///
/// The Hypervisor.framework requires that `hv_vcpu_create`, `hv_vcpu_run`,
/// and `hv_vcpu_destroy` are all called from the same thread. This class
/// creates a pthread and runs the entire vCPU lifecycle on it.
public final class VCPUThread: @unchecked Sendable {
    /// Zero-based vCPU index.
    public let index: Int

    /// The exit handler that dispatches vCPU exits.
    public let exitHandler: VCPUExitHandler

    /// Callback invoked when the virtual timer fires.
    public var onVTimerActivated: ((hv_vcpu_t) -> Void)?

    /// Callback invoked when the vCPU is created (before the run loop).
    /// Use this to set initial register state.
    public var onVCPUCreated: ((hv_vcpu_t) -> Void)?

    /// Callback invoked when the vCPU stops (after the run loop exits).
    public var onVCPUStopped: ((hv_vcpu_t) -> Void)?

    // Internal state
    private var thread: Thread?
    private var vcpuHandle: hv_vcpu_t = 0
    private let cancelledFlag = AtomicFlag()
    private let pausedFlag = AtomicFlag()
    private let pauseSemaphore = DispatchSemaphore(value: 0)
    private let resumeSemaphore = DispatchSemaphore(value: 0)
    private let startedSemaphore = DispatchSemaphore(value: 0)
    private var startError: hv_return_t = 0 // HV_SUCCESS

    public init(index: Int, exitHandler: VCPUExitHandler) {
        self.index = index
        self.exitHandler = exitHandler
    }

    /// Start the vCPU thread. Blocks until the vCPU is created.
    /// Throws if vCPU creation fails.
    public func start() throws {
        cancelledFlag.clear()
        pausedFlag.clear()
        startError = 0 // HV_SUCCESS

        let t = Thread { [weak self] in
            self?.runLoop()
        }
        t.name = "vortex.vcpu.\(index)"
        t.qualityOfService = .userInteractive
        self.thread = t
        t.start()

        // Wait for the vCPU to be created on the thread.
        startedSemaphore.wait()
        if startError != HV_SUCCESS {
            throw VCPUError.createFailed(index: index, code: startError)
        }
    }

    /// Request the vCPU to stop. Non-blocking -- the run loop will exit
    /// after the current `hv_vcpu_run` returns.
    public func cancel() {
        cancelledFlag.set()
        // If paused, resume so the loop can exit.
        if pausedFlag.load() {
            resumeSemaphore.signal()
        }
        // Force exit the vCPU if it is running.
        let handle = vcpuHandle
        if handle != 0 {
            var vcpus = [handle]
            _ = hv_vcpus_exit(&vcpus, 1)
        }
    }

    /// Pause the vCPU. The run loop will block at the next iteration.
    public func pause() {
        pausedFlag.set()
        let handle = vcpuHandle
        if handle != 0 {
            var vcpus = [handle]
            _ = hv_vcpus_exit(&vcpus, 1)
        }
    }

    /// Resume a paused vCPU.
    public func resume() {
        if pausedFlag.load() {
            pausedFlag.clear()
            resumeSemaphore.signal()
        }
    }

    /// The raw Hypervisor.framework vCPU handle. Only valid while running.
    public var handle: hv_vcpu_t { vcpuHandle }

    // MARK: - Run Loop

    private func runLoop() {
        // Create the vCPU on this thread.
        var vcpu: hv_vcpu_t = 0
        var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>?
        let ret = hv_vcpu_create(&vcpu, &exitInfo, nil)
        if ret != HV_SUCCESS {
            startError = ret
            startedSemaphore.signal()
            return
        }
        vcpuHandle = vcpu

        // Signal that creation succeeded.
        startedSemaphore.signal()

        // Set up initial state via callback.
        onVCPUCreated?(vcpu)

        guard let exitPtr = exitInfo else {
            VortexLog.hv.error("VCPU \(self.index): exit info pointer is nil after creation")
            _ = hv_vcpu_destroy(vcpu)
            vcpuHandle = 0
            return
        }

        // Main run loop.
        while !cancelledFlag.load() {
            // Check for pause.
            if pausedFlag.load() {
                pauseSemaphore.signal()
                resumeSemaphore.wait()
                // After resume, check if we were cancelled while paused.
                if cancelledFlag.load() { break }
            }

            // Execute the vCPU until it exits.
            let runRet = hv_vcpu_run(vcpu)
            if runRet != HV_SUCCESS {
                VortexLog.hv.error("VCPU \(self.index): hv_vcpu_run failed with error \(runRet)")
                break
            }

            let exit = exitPtr.pointee

            switch exit.reason {
            case HV_EXIT_REASON_EXCEPTION:
                let shouldContinue = exitHandler.handleException(vcpu: vcpu, exit: exit)
                if !shouldContinue {
                    VortexLog.hv.info("VCPU \(self.index): exit handler requested stop")
                    cancelledFlag.set()
                }

            case HV_EXIT_REASON_VTIMER_ACTIVATED:
                onVTimerActivated?(vcpu)

            case HV_EXIT_REASON_CANCELED:
                // Explicit cancel via hv_vcpus_exit or internal cancellation.
                // Loop will check cancelledFlag / pausedFlag.
                break

            default:
                VortexLog.hv.error("VCPU \(self.index): unknown exit reason \(exit.reason.rawValue)")
                cancelledFlag.set()
            }
        }

        // Notify and destroy.
        onVCPUStopped?(vcpu)
        _ = hv_vcpu_destroy(vcpu)
        vcpuHandle = 0
    }

    // MARK: - Register Access (must be called from vcpu thread or when paused)

    /// Get a general purpose register value.
    public func getRegister(_ reg: hv_reg_t) -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpuHandle, reg, &value)
        return value
    }

    /// Set a general purpose register value.
    public func setRegister(_ reg: hv_reg_t, value: UInt64) {
        _ = hv_vcpu_set_reg(vcpuHandle, reg, value)
    }

    /// Get a system register value.
    public func getSysRegister(_ reg: hv_sys_reg_t) -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(vcpuHandle, reg, &value)
        return value
    }

    /// Set a system register value.
    public func setSysRegister(_ reg: hv_sys_reg_t, value: UInt64) {
        _ = hv_vcpu_set_sys_reg(vcpuHandle, reg, value)
    }

    /// Get the program counter.
    public func getPC() -> UInt64 { getRegister(HV_REG_PC) }

    /// Set the program counter.
    public func setPC(_ value: UInt64) { setRegister(HV_REG_PC, value: value) }

    /// Get the stack pointer (SP_EL0).
    public func getSP() -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(vcpuHandle, HV_SYS_REG_SP_EL0, &value)
        return value
    }

    /// Set the stack pointer (SP_EL0).
    public func setSP(_ value: UInt64) {
        _ = hv_vcpu_set_sys_reg(vcpuHandle, HV_SYS_REG_SP_EL0, value)
    }

    /// Get the current program status register.
    public func getCPSR() -> UInt64 { getRegister(HV_REG_CPSR) }

    /// Set the current program status register.
    public func setCPSR(_ value: UInt64) { setRegister(HV_REG_CPSR, value: value) }

    /// Get a general purpose register by index (0-30).
    public func getX(_ index: Int) -> UInt64 {
        guard index < 31 else { return 0 }
        let reg = hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(index))
        return getRegister(reg)
    }

    /// Set a general purpose register by index (0-30).
    public func setX(_ index: Int, value: UInt64) {
        guard index < 31 else { return }
        let reg = hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(index))
        setRegister(reg, value: value)
    }

    /// Set the pending interrupt state for this vCPU.
    public func setPendingInterrupt(type: hv_interrupt_type_t, pending: Bool) {
        _ = hv_vcpu_set_pending_interrupt(vcpuHandle, type, pending)
    }

    /// Get the pending interrupt state for this vCPU.
    public func getPendingInterrupt(type: hv_interrupt_type_t) -> Bool {
        var pending = false
        _ = hv_vcpu_get_pending_interrupt(vcpuHandle, type, &pending)
        return pending
    }

    /// Set the VTimer mask.
    public func setVTimerMask(_ masked: Bool) {
        _ = hv_vcpu_set_vtimer_mask(vcpuHandle, masked)
    }

    /// Get the VTimer offset.
    public func getVTimerOffset() -> UInt64 {
        var offset: UInt64 = 0
        _ = hv_vcpu_get_vtimer_offset(vcpuHandle, &offset)
        return offset
    }

    /// Set the VTimer offset.
    public func setVTimerOffset(_ offset: UInt64) {
        _ = hv_vcpu_set_vtimer_offset(vcpuHandle, offset)
    }
}

// MARK: - Atomic Flag

/// A simple atomic boolean for cross-thread signaling.
internal final class AtomicFlag: @unchecked Sendable {
    private var _value: Int32 = 0

    func set() {
        OSAtomicOr32Barrier(1, &_value)
    }

    func clear() {
        OSAtomicAnd32Barrier(0, &_value)
    }

    func load() -> Bool {
        OSAtomicOr32Barrier(0, &_value) != 0
    }
}

// MARK: - Errors

public enum VCPUError: Error, CustomStringConvertible {
    case createFailed(index: Int, code: hv_return_t)

    public var description: String {
        switch self {
        case .createFailed(let index, let code):
            return "Failed to create vCPU \(index): error \(code)"
        }
    }
}
