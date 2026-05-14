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
    private var hasVCPUHandle = false
    private let cancelledFlag = AtomicFlag()
    private let pausedFlag = AtomicFlag()
    private let runningFlag = AtomicFlag()
    private let pauseSemaphore = DispatchSemaphore(value: 0)
    private let resumeSemaphore = DispatchSemaphore(value: 0)
    private let startedSemaphore = DispatchSemaphore(value: 0)
    private var startError: hv_return_t = 0 // HV_SUCCESS
    private let diagnosticsLock = NSLock()
    private var lastPC: UInt64 = 0
    private var lastExitReason: UInt32?
    private var exitCount: UInt64 = 0
    private var lastForceExitReturn: hv_return_t?
    private var lastLiveRegisterReadReturn: hv_return_t?
    private var lastRegisters = RegisterSnapshot.zero

    public init(index: Int, exitHandler: VCPUExitHandler) {
        self.index = index
        self.exitHandler = exitHandler
    }

    /// Start the vCPU thread. Blocks until the vCPU is created.
    /// Throws if vCPU creation fails.
    public func start() throws {
        guard !runningFlag.load() else {
            throw VCPUError.alreadyStarted(index: index)
        }

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
            runningFlag.clear()
            throw VCPUError.createFailed(index: index, code: startError)
        }
        runningFlag.set()
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
        if let handle = currentValidHandle() {
            var vcpus = [handle]
            _ = hv_vcpus_exit(&vcpus, 1)
        }
    }

    /// Pause the vCPU. The run loop will block at the next iteration.
    public func pause() {
        pausedFlag.set()
        if let handle = currentValidHandle() {
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
    public var handle: hv_vcpu_t { currentHandle() }

    /// Whether this thread currently owns a live vCPU.
    public var isRunning: Bool { runningFlag.load() }

    public struct Diagnostics: Sendable {
        public let index: Int
        public let isRunning: Bool
        public let lastPC: UInt64
        public let lastExitReason: UInt32?
        public let exitCount: UInt64
        public let lastForceExitReturn: hv_return_t?
        public let lastLiveRegisterReadReturn: hv_return_t?
        public let registers: RegisterSnapshot
    }

    public struct RegisterSnapshot: Sendable {
        public let x0: UInt64
        public let x1: UInt64
        public let x2: UInt64
        public let x3: UInt64
        public let x19: UInt64
        public let x29: UInt64
        public let x30: UInt64
        public let spEL0: UInt64
        public let spEL1: UInt64
        public let cpsr: UInt64

        public static let zero = RegisterSnapshot(
            x0: 0,
            x1: 0,
            x2: 0,
            x3: 0,
            x19: 0,
            x29: 0,
            x30: 0,
            spEL0: 0,
            spEL1: 0,
            cpsr: 0
        )
    }

    public func diagnostics(forceExit: Bool = false) -> Diagnostics {
        let initialCount: UInt64
        let handle: hv_vcpu_t
        let hasHandle: Bool
        diagnosticsLock.lock()
        handle = vcpuHandle
        hasHandle = hasVCPUHandle
        initialCount = exitCount
        diagnosticsLock.unlock()

        if forceExit {
            if hasHandle {
                var vcpus = [handle]
                let exitRet = hv_vcpus_exit(&vcpus, 1)
                recordForceExitReturn(exitRet)
                waitForDiagnosticExit(after: initialCount)
                refreshLiveState(handle: handle)
            }
        }

        return diagnosticSnapshot()
    }

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
        setCurrentHandle(vcpu)

        // Signal that creation succeeded.
        startedSemaphore.signal()

        // Set up initial state via callback.
        onVCPUCreated?(vcpu)
        recordState(vcpu: vcpu, exitReason: nil, incrementsExitCount: false)

        guard let exitPtr = exitInfo else {
            VortexLog.hv.error("VCPU \(self.index): exit info pointer is nil after creation")
            _ = hv_vcpu_destroy(vcpu)
            clearCurrentHandle()
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
            record(exit: exit, vcpu: vcpu)

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
        clearCurrentHandle()
        runningFlag.clear()
    }

    private func record(exit: hv_vcpu_exit_t, vcpu: hv_vcpu_t) {
        recordState(vcpu: vcpu, exitReason: exit.reason.rawValue, incrementsExitCount: true)
    }

    private func recordState(
        vcpu: hv_vcpu_t,
        exitReason: UInt32?,
        incrementsExitCount: Bool
    ) {
        var pc: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
        let registers = readRegisterSnapshot(vcpu: vcpu)
        diagnosticsLock.lock()
        lastPC = pc
        lastRegisters = registers
        lastExitReason = exitReason
        if incrementsExitCount {
            exitCount &+= 1
        }
        diagnosticsLock.unlock()
    }

    private func currentHandle() -> hv_vcpu_t {
        diagnosticsLock.lock()
        let handle = vcpuHandle
        diagnosticsLock.unlock()
        return handle
    }

    private func currentValidHandle() -> hv_vcpu_t? {
        diagnosticsLock.lock()
        let handle = hasVCPUHandle ? vcpuHandle : nil
        diagnosticsLock.unlock()
        return handle
    }

    private func setCurrentHandle(_ handle: hv_vcpu_t) {
        diagnosticsLock.lock()
        vcpuHandle = handle
        hasVCPUHandle = true
        diagnosticsLock.unlock()
    }

    private func clearCurrentHandle() {
        diagnosticsLock.lock()
        vcpuHandle = 0
        hasVCPUHandle = false
        diagnosticsLock.unlock()
    }

    private func diagnosticSnapshot() -> Diagnostics {
        diagnosticsLock.lock()
        let snapshot = Diagnostics(
            index: index,
            isRunning: isRunning,
            lastPC: lastPC,
            lastExitReason: lastExitReason,
            exitCount: exitCount,
            lastForceExitReturn: lastForceExitReturn,
            lastLiveRegisterReadReturn: lastLiveRegisterReadReturn,
            registers: lastRegisters
        )
        diagnosticsLock.unlock()
        return snapshot
    }

    private func recordForceExitReturn(_ ret: hv_return_t) {
        diagnosticsLock.lock()
        lastForceExitReturn = ret
        diagnosticsLock.unlock()
    }

    private func refreshLiveState(handle: hv_vcpu_t) {
        var pc: UInt64 = 0
        let ret = hv_vcpu_get_reg(handle, HV_REG_PC, &pc)
        diagnosticsLock.lock()
        lastLiveRegisterReadReturn = ret
        if ret == HV_SUCCESS {
            lastPC = pc
        }
        diagnosticsLock.unlock()
    }

    private func readRegisterSnapshot(vcpu: hv_vcpu_t) -> RegisterSnapshot {
        RegisterSnapshot(
            x0: readGPR(vcpu: vcpu, index: 0),
            x1: readGPR(vcpu: vcpu, index: 1),
            x2: readGPR(vcpu: vcpu, index: 2),
            x3: readGPR(vcpu: vcpu, index: 3),
            x19: readGPR(vcpu: vcpu, index: 19),
            x29: readGPR(vcpu: vcpu, index: 29),
            x30: readGPR(vcpu: vcpu, index: 30),
            spEL0: readSysReg(vcpu: vcpu, reg: HV_SYS_REG_SP_EL0),
            spEL1: readSysReg(vcpu: vcpu, reg: HV_SYS_REG_SP_EL1),
            cpsr: readReg(vcpu: vcpu, reg: HV_REG_CPSR)
        )
    }

    private func readGPR(vcpu: hv_vcpu_t, index: Int) -> UInt64 {
        let reg = hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(index))
        return readReg(vcpu: vcpu, reg: reg)
    }

    private func readReg(vcpu: hv_vcpu_t, reg: hv_reg_t) -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpu, reg, &value)
        return value
    }

    private func readSysReg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t) -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(vcpu, reg, &value)
        return value
    }

    private func waitForDiagnosticExit(after initialCount: UInt64) {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            diagnosticsLock.lock()
            let didExit = exitCount != initialCount || !hasVCPUHandle
            diagnosticsLock.unlock()
            if didExit {
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    // MARK: - Register Access (must be called from vcpu thread or when paused)

    /// Get a general purpose register value.
    public func getRegister(_ reg: hv_reg_t) -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_reg(currentHandle(), reg, &value)
        return value
    }

    /// Set a general purpose register value.
    public func setRegister(_ reg: hv_reg_t, value: UInt64) {
        _ = hv_vcpu_set_reg(currentHandle(), reg, value)
    }

    /// Get a system register value.
    public func getSysRegister(_ reg: hv_sys_reg_t) -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(currentHandle(), reg, &value)
        return value
    }

    /// Set a system register value.
    public func setSysRegister(_ reg: hv_sys_reg_t, value: UInt64) {
        _ = hv_vcpu_set_sys_reg(currentHandle(), reg, value)
    }

    /// Get the program counter.
    public func getPC() -> UInt64 { getRegister(HV_REG_PC) }

    /// Set the program counter.
    public func setPC(_ value: UInt64) { setRegister(HV_REG_PC, value: value) }

    /// Get the stack pointer (SP_EL0).
    public func getSP() -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_sys_reg(currentHandle(), HV_SYS_REG_SP_EL0, &value)
        return value
    }

    /// Set the stack pointer (SP_EL0).
    public func setSP(_ value: UInt64) {
        _ = hv_vcpu_set_sys_reg(currentHandle(), HV_SYS_REG_SP_EL0, value)
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
        _ = hv_vcpu_set_pending_interrupt(currentHandle(), type, pending)
    }

    /// Get the pending interrupt state for this vCPU.
    public func getPendingInterrupt(type: hv_interrupt_type_t) -> Bool {
        var pending = false
        _ = hv_vcpu_get_pending_interrupt(currentHandle(), type, &pending)
        return pending
    }

    /// Set the VTimer mask.
    public func setVTimerMask(_ masked: Bool) {
        _ = hv_vcpu_set_vtimer_mask(currentHandle(), masked)
    }

    /// Get the VTimer offset.
    public func getVTimerOffset() -> UInt64 {
        var offset: UInt64 = 0
        _ = hv_vcpu_get_vtimer_offset(currentHandle(), &offset)
        return offset
    }

    /// Set the VTimer offset.
    public func setVTimerOffset(_ offset: UInt64) {
        _ = hv_vcpu_set_vtimer_offset(currentHandle(), offset)
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
    case alreadyStarted(index: Int)
    case createFailed(index: Int, code: hv_return_t)

    public var description: String {
        switch self {
        case .alreadyStarted(let index):
            return "vCPU \(index) is already running"
        case .createFailed(let index, let code):
            return "Failed to create vCPU \(index): error \(code)"
        }
    }
}
