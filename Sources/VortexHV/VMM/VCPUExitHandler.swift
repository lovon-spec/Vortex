// VCPUExitHandler.swift -- Exit reason dispatch and ESR decoding.
// VortexHV

import Foundation
import Hypervisor
import VortexCore

// MARK: - ESR_EL2 Constants

/// ARM Exception Syndrome Register (ESR_EL2) field extraction helpers.
public enum ESR {
    // Exception class (bits [31:26])
    public static let ecShift: UInt64 = 26
    public static let ecMask: UInt64 = 0x3F

    // Instruction length (bit 25) -- 0 = 16-bit, 1 = 32-bit
    public static let ilBit: UInt64 = 1 << 25

    // ISS field (bits [24:0])
    public static let issMask: UInt64 = 0x1FF_FFFF

    // Exception classes relevant to VMM
    public static let ecUnknown: UInt64 = 0x00
    public static let ecWFxTrap: UInt64 = 0x01      // WFI/WFE trap
    public static let ecHVC64: UInt64 = 0x16         // HVC from AArch64
    public static let ecSMC64: UInt64 = 0x17         // SMC from AArch64
    public static let ecSysRegTrap: UInt64 = 0x18    // MSR/MRS trap
    public static let ecInstrAbort: UInt64 = 0x20    // Instruction abort from lower EL
    public static let ecDataAbort: UInt64 = 0x24     // Data abort from lower EL

    // Data abort ISS fields
    public static let issSRTShift: UInt64 = 16       // Syndrome Register Transfer (Xt)
    public static let issSRTMask: UInt64 = 0x1F
    public static let issSFBit: UInt64 = 1 << 15     // Sixty-Four bit register
    public static let issARBit: UInt64 = 1 << 14     // Acquire/Release
    public static let issVNCRBit: UInt64 = 1 << 13
    public static let issSETShift: UInt64 = 11
    public static let issSETMask: UInt64 = 0x3
    public static let issFnVBit: UInt64 = 1 << 10    // FAR not valid
    public static let issEABit: UInt64 = 1 << 9      // External abort
    public static let issCMBit: UInt64 = 1 << 8      // Cache maintenance
    public static let issS1PTWBit: UInt64 = 1 << 7   // Stage 1 page table walk
    public static let issWnRBit: UInt64 = 1 << 6     // Write not Read (1 = write)
    public static let issSASShift: UInt64 = 22        // Syndrome Access Size
    public static let issSASMask: UInt64 = 0x3
    public static let issSSEBit: UInt64 = 1 << 21    // Syndrome Sign Extend
    public static let issISVBit: UInt64 = 1 << 24    // Instruction Syndrome Valid

    /// Extract the exception class from an ESR value.
    public static func exceptionClass(_ esr: UInt64) -> UInt64 {
        (esr >> ecShift) & ecMask
    }

    /// Check if the trapped instruction was 32-bit.
    public static func is32BitInstruction(_ esr: UInt64) -> Bool {
        (esr & ilBit) != 0
    }

    /// Extract the ISS field.
    public static func issField(_ esr: UInt64) -> UInt64 {
        esr & issMask
    }
}

// MARK: - Decoded Data Abort

/// Decoded information from a data abort ESR for MMIO emulation.
public struct DataAbortInfo {
    /// Guest physical address that was accessed (from FAR_EL2 / exit.physical_address).
    public let faultAddress: UInt64
    /// Whether this is a write (true) or read (false).
    public let isWrite: Bool
    /// Access size in bytes (1, 2, 4, or 8).
    public let accessSize: Int
    /// Register index (X0-X30) for the transfer.
    public let registerIndex: Int
    /// Whether the register is 64-bit (true) or 32-bit (false).
    public let is64Bit: Bool
    /// Whether sign extension is needed.
    public let signExtend: Bool
    /// Whether ISS is valid (ISV bit set).
    public let issValid: Bool
    /// Instruction length (2 or 4 bytes).
    public let instructionLength: Int
}

// MARK: - HVC Info

/// Decoded HVC/SMC call information.
public struct HypercallInfo {
    /// The immediate value in the HVC/SMC instruction (bits [15:0] of ISS).
    public let immediate: UInt16
    /// Whether this is an SMC (true) or HVC (false).
    public let isSMC: Bool
}

// MARK: - VCPU Exit Handler

/// Decodes vCPU exit reasons and dispatches to the appropriate handler.
public final class VCPUExitHandler: @unchecked Sendable {
    /// The address space for MMIO dispatch.
    public let addressSpace: AddressSpace

    /// Callback for HVC/SMC calls (PSCI, etc.).
    /// Parameters: vcpu handle, hypercall info, registers X0-X3.
    /// Returns: true if the call was handled.
    public var onHypercall: ((hv_vcpu_t, HypercallInfo) -> Bool)?

    /// Callback for WFI/WFE traps.
    public var onWFx: ((hv_vcpu_t, Bool) -> Void)? // Bool: true = WFE, false = WFI

    public init(addressSpace: AddressSpace) {
        self.addressSpace = addressSpace
    }

    // MARK: - Exit Dispatch

    /// Handle a vCPU exit exception. Called from the vCPU run loop.
    ///
    /// - Parameters:
    ///   - vcpu: The vCPU handle.
    ///   - exit: The exit information struct.
    /// - Returns: Whether the vCPU should continue running.
    public func handleException(vcpu: hv_vcpu_t, exit: hv_vcpu_exit_t) -> Bool {
        let syndrome = exit.exception.syndrome
        let ec = ESR.exceptionClass(syndrome)

        switch ec {
        case ESR.ecDataAbort:
            return handleDataAbort(vcpu: vcpu, exit: exit)

        case ESR.ecHVC64:
            return handleHVC(vcpu: vcpu, syndrome: syndrome)

        case ESR.ecSMC64:
            return handleSMC(vcpu: vcpu, syndrome: syndrome)

        case ESR.ecWFxTrap:
            return handleWFx(vcpu: vcpu, syndrome: syndrome)

        case ESR.ecSysRegTrap:
            return handleSysRegTrap(vcpu: vcpu, syndrome: syndrome)

        default:
            // Unhandled exception class -- log and stop.
            let pc = getRegister(vcpu: vcpu, reg: HV_REG_PC)
            VortexLog.hv.error("Unhandled exception class 0x\(String(ec, radix: 16)) at PC=0x\(String(pc, radix: 16)), ESR=0x\(String(syndrome, radix: 16))")
            return false
        }
    }

    // MARK: - Data Abort (MMIO)

    private func handleDataAbort(vcpu: hv_vcpu_t, exit: hv_vcpu_exit_t) -> Bool {
        let syndrome = exit.exception.syndrome
        let iss = ESR.issField(syndrome)

        // Check ISV (Instruction Syndrome Valid) -- if not set, we can't decode the access.
        let issValid = (iss & (1 << 24)) != 0
        guard issValid else {
            let pc = getRegister(vcpu: vcpu, reg: HV_REG_PC)
            VortexLog.hv.error("Data abort with ISV=0 at PC=0x\(String(pc, radix: 16)) -- cannot decode MMIO")
            return false
        }

        let info = decodeDataAbort(syndrome: syndrome, faultAddress: exit.exception.physical_address)

        if info.isWrite {
            // Read the value from the source register.
            let value = readGPR(vcpu: vcpu, index: info.registerIndex, is64Bit: info.is64Bit)
            addressSpace.write(at: info.faultAddress, size: info.accessSize, value: value)
        } else {
            // Read from device, write result to destination register.
            var value = addressSpace.read(at: info.faultAddress, size: info.accessSize)

            // Apply sign extension if needed.
            if info.signExtend {
                value = signExtend(value: value, accessSize: info.accessSize, is64Bit: info.is64Bit)
            }

            writeGPR(vcpu: vcpu, index: info.registerIndex, is64Bit: info.is64Bit, value: value)
        }

        // Advance PC past the faulting instruction.
        advancePC(vcpu: vcpu, instructionLength: info.instructionLength)
        return true
    }

    /// Decode the ESR syndrome and physical address into a DataAbortInfo.
    public func decodeDataAbort(syndrome: UInt64, faultAddress: UInt64) -> DataAbortInfo {
        let iss = ESR.issField(syndrome)
        let isWrite = (iss & ESR.issWnRBit) != 0
        let sasField = (iss >> ESR.issSASShift) & ESR.issSASMask
        let accessSize = 1 << Int(sasField) // 0->1, 1->2, 2->4, 3->8
        let registerIndex = Int((iss >> ESR.issSRTShift) & ESR.issSRTMask)
        let is64Bit = (iss & ESR.issSFBit) != 0
        let signExtend = (iss & ESR.issSSEBit) != 0
        let issValid = (iss & ESR.issISVBit) != 0
        let instrLen = ESR.is32BitInstruction(syndrome) ? 4 : 2

        return DataAbortInfo(
            faultAddress: faultAddress,
            isWrite: isWrite,
            accessSize: accessSize,
            registerIndex: registerIndex,
            is64Bit: is64Bit,
            signExtend: signExtend,
            issValid: issValid,
            instructionLength: instrLen
        )
    }

    // MARK: - HVC / SMC

    private func handleHVC(vcpu: hv_vcpu_t, syndrome: UInt64) -> Bool {
        let imm = UInt16(ESR.issField(syndrome) & 0xFFFF)
        let info = HypercallInfo(immediate: imm, isSMC: false)

        if let handler = onHypercall, handler(vcpu, info) {
            // Handler advanced PC if needed.
            return true
        }

        // Unhandled HVC -- advance PC and return unknown function in X0.
        setRegister(vcpu: vcpu, reg: HV_REG_X0, value: UInt64(bitPattern: -1)) // PSCI NOT_SUPPORTED
        advancePC(vcpu: vcpu, instructionLength: 4)
        return true
    }

    private func handleSMC(vcpu: hv_vcpu_t, syndrome: UInt64) -> Bool {
        let imm = UInt16(ESR.issField(syndrome) & 0xFFFF)
        let info = HypercallInfo(immediate: imm, isSMC: true)

        if let handler = onHypercall, handler(vcpu, info) {
            return true
        }

        // Unhandled SMC -- return NOT_SUPPORTED and advance past the SMC instruction.
        setRegister(vcpu: vcpu, reg: HV_REG_X0, value: UInt64(bitPattern: -1))
        // For SMC, the PC needs to advance by 4 (ELR_EL2 points at SMC instruction).
        advancePC(vcpu: vcpu, instructionLength: 4)
        return true
    }

    // MARK: - WFI / WFE

    private func handleWFx(vcpu: hv_vcpu_t, syndrome: UInt64) -> Bool {
        let isWFE = (ESR.issField(syndrome) & 0x1) != 0
        onWFx?(vcpu, isWFE)

        // Advance past the WFI/WFE instruction.
        let instrLen = ESR.is32BitInstruction(syndrome) ? 4 : 2
        advancePC(vcpu: vcpu, instructionLength: instrLen)
        return true
    }

    // MARK: - System Register Trap

    private func handleSysRegTrap(vcpu: hv_vcpu_t, syndrome: UInt64) -> Bool {
        // For now, log and skip. A full implementation would decode the
        // Op0/Op1/CRn/CRm/Op2 fields and emulate the register.
        let pc = getRegister(vcpu: vcpu, reg: HV_REG_PC)
        let iss = ESR.issField(syndrome)
        let isRead = (iss & 0x1) != 0 // Direction: 0 = write (MSR), 1 = read (MRS)
        let op0 = (iss >> 20) & 0x3
        let op1 = (iss >> 14) & 0x7
        let crn = (iss >> 10) & 0xF
        let crm = (iss >> 1) & 0xF
        let op2 = (iss >> 17) & 0x7
        let rt = Int((iss >> 5) & 0x1F)

        VortexLog.hv.debug("SysReg trap at PC=0x\(String(pc, radix: 16)): \(isRead ? "MRS" : "MSR") S\(op0)_\(op1)_C\(crn)_C\(crm)_\(op2) Xt=X\(rt)")

        if isRead {
            // Return zero for unimplemented system registers.
            writeGPR(vcpu: vcpu, index: rt, is64Bit: true, value: 0)
        }

        advancePC(vcpu: vcpu, instructionLength: 4) // System register instructions are always 32-bit.
        return true
    }

    // MARK: - Register Helpers

    /// Read a general purpose register.
    public func readGPR(vcpu: hv_vcpu_t, index: Int, is64Bit: Bool) -> UInt64 {
        guard index < 31 else { return 0 } // XZR reads as zero
        let reg = hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(index))
        var value: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpu, reg, &value)
        if !is64Bit {
            value &= 0xFFFF_FFFF
        }
        return value
    }

    /// Write a general purpose register.
    public func writeGPR(vcpu: hv_vcpu_t, index: Int, is64Bit: Bool, value: UInt64) {
        guard index < 31 else { return } // Writes to XZR are discarded
        let reg = hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(index))
        let maskedValue = is64Bit ? value : (value & 0xFFFF_FFFF)
        _ = hv_vcpu_set_reg(vcpu, reg, maskedValue)
    }

    private func getRegister(vcpu: hv_vcpu_t, reg: hv_reg_t) -> UInt64 {
        var value: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpu, reg, &value)
        return value
    }

    private func setRegister(vcpu: hv_vcpu_t, reg: hv_reg_t, value: UInt64) {
        _ = hv_vcpu_set_reg(vcpu, reg, value)
    }

    /// Advance the PC by the given instruction length.
    public func advancePC(vcpu: hv_vcpu_t, instructionLength: Int) {
        var pc: UInt64 = 0
        _ = hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
        _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc &+ UInt64(instructionLength))
    }

    // MARK: - Sign Extension

    private func signExtend(value: UInt64, accessSize: Int, is64Bit: Bool) -> UInt64 {
        let bits = accessSize * 8
        let signBit: UInt64 = 1 << (bits - 1)
        if (value & signBit) != 0 {
            // Sign bit is set -- extend with ones.
            let mask: UInt64 = is64Bit ? ~((1 << bits) - 1) : (~((1 << bits) - 1)) & 0xFFFF_FFFF
            return value | mask
        }
        return value
    }
}
