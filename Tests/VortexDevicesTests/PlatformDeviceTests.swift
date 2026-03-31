// PlatformDeviceTests.swift -- Unit tests for PL011 UART, PL031 RTC,
// CFI Flash, and PSCI Power Controller.
// VortexDevicesTests

#if canImport(XCTest)
import XCTest
@testable import VortexDevices
@testable import VortexHV

// MARK: - PL011 UART Tests

final class PL011UARTTests: XCTestCase {

    // MARK: - Initialization and Properties

    func testDefaultBaseAddress() {
        let uart = PL011UART()
        XCTAssertEqual(uart.baseAddress, MachineMemoryMap.uart0Base)
        XCTAssertEqual(uart.regionSize, MachineMemoryMap.uart0Size)
    }

    func testCustomBaseAddress() {
        let uart = PL011UART(baseAddress: 0x1000_0000)
        XCTAssertEqual(uart.baseAddress, 0x1000_0000)
    }

    // MARK: - PrimeCell ID Registers

    func testPrimeCellIDRegisters() {
        let uart = PL011UART()

        // Peripheral ID registers
        XCTAssertEqual(uart.mmioRead(offset: 0xFE0, size: 4), 0x11)
        XCTAssertEqual(uart.mmioRead(offset: 0xFE4, size: 4), 0x10)
        XCTAssertEqual(uart.mmioRead(offset: 0xFE8, size: 4), 0x14)
        XCTAssertEqual(uart.mmioRead(offset: 0xFEC, size: 4), 0x00)

        // Cell ID registers
        XCTAssertEqual(uart.mmioRead(offset: 0xFF0, size: 4), 0x0D)
        XCTAssertEqual(uart.mmioRead(offset: 0xFF4, size: 4), 0xF0)
        XCTAssertEqual(uart.mmioRead(offset: 0xFF8, size: 4), 0x05)
        XCTAssertEqual(uart.mmioRead(offset: 0xFFC, size: 4), 0xB1)
    }

    // MARK: - Flag Register

    func testFlagRegisterInitialState() {
        let uart = PL011UART()
        let flags = UInt32(uart.mmioRead(offset: 0x018, size: 4))

        // TX FIFO should be empty (TXFE set), RX FIFO should be empty (RXFE set).
        XCTAssertNotEqual(flags & (1 << 7), 0, "TXFE should be set")
        XCTAssertNotEqual(flags & (1 << 4), 0, "RXFE should be set")
        XCTAssertEqual(flags & (1 << 5), 0, "TXFF should be clear")
    }

    func testFlagRegisterAfterRXInjection() {
        let uart = PL011UART()
        uart.injectCharacter(0x41)

        let flags = UInt32(uart.mmioRead(offset: 0x018, size: 4))
        // RX FIFO no longer empty.
        XCTAssertEqual(flags & (1 << 4), 0, "RXFE should be clear after injection")
    }

    // MARK: - TX Output

    func testWriteDataRegisterCallsOutputCallback() {
        let uart = PL011UART()
        var outputBytes: [UInt8] = []
        uart.onOutput = { byte in
            outputBytes.append(byte)
        }

        // Enable UART and TX.
        uart.mmioWrite(offset: 0x030, size: 4, value: UInt64(0x301)) // UARTEN | TXE | RXE

        // Write a character.
        uart.mmioWrite(offset: 0x000, size: 4, value: 0x48) // 'H'
        uart.mmioWrite(offset: 0x000, size: 4, value: 0x69) // 'i'

        XCTAssertEqual(outputBytes, [0x48, 0x69])
    }

    func testWriteDataRegisterWithoutEnableDoesNotOutput() {
        let uart = PL011UART()
        var outputCalled = false
        uart.onOutput = { _ in
            outputCalled = true
        }

        // UART not enabled -- write should be ignored.
        uart.mmioWrite(offset: 0x000, size: 4, value: 0x41)
        XCTAssertFalse(outputCalled)
    }

    // MARK: - RX Input

    func testInjectAndReadCharacter() {
        let uart = PL011UART()
        uart.injectCharacter(0x41) // 'A'
        uart.injectCharacter(0x42) // 'B'

        let a = uart.mmioRead(offset: 0x000, size: 4)
        let b = uart.mmioRead(offset: 0x000, size: 4)

        XCTAssertEqual(a, 0x41)
        XCTAssertEqual(b, 0x42)
    }

    func testReadEmptyRXReturnsZero() {
        let uart = PL011UART()
        let value = uart.mmioRead(offset: 0x000, size: 4)
        XCTAssertEqual(value, 0)
    }

    func testInjectString() {
        let uart = PL011UART()
        uart.injectString("Hi")

        let h = uart.mmioRead(offset: 0x000, size: 4)
        let i = uart.mmioRead(offset: 0x000, size: 4)

        XCTAssertEqual(h, UInt64(Character("H").asciiValue!))
        XCTAssertEqual(i, UInt64(Character("i").asciiValue!))
    }

    // MARK: - Interrupt Handling

    func testRXInterruptSetOnInject() {
        let uart = PL011UART()
        var interruptAsserted = false
        uart.onInterruptStateChanged = { active in
            interruptAsserted = active
        }

        // Enable RX interrupt mask (bit 4).
        uart.mmioWrite(offset: 0x038, size: 4, value: UInt64(1 << 4))

        // Inject a character -- should trigger RX interrupt.
        uart.injectCharacter(0x41)
        XCTAssertTrue(interruptAsserted)

        // Raw interrupt status should have RX bit set.
        let ris = uart.mmioRead(offset: 0x03C, size: 4)
        XCTAssertNotEqual(ris & UInt64(1 << 4), 0, "RXIS should be set")

        // Masked interrupt status should also have RX bit set.
        let mis = uart.mmioRead(offset: 0x040, size: 4)
        XCTAssertNotEqual(mis & UInt64(1 << 4), 0, "Masked RXIS should be set")
    }

    func testTXInterruptSetOnWrite() {
        let uart = PL011UART()

        // Enable UART and TX.
        uart.mmioWrite(offset: 0x030, size: 4, value: UInt64(0x301))

        // Enable TX interrupt mask (bit 5).
        uart.mmioWrite(offset: 0x038, size: 4, value: UInt64(1 << 5))

        // Write a character -- TX completes instantly in emulation.
        uart.mmioWrite(offset: 0x000, size: 4, value: 0x41)

        let ris = uart.mmioRead(offset: 0x03C, size: 4)
        XCTAssertNotEqual(ris & UInt64(1 << 5), 0, "TXIS should be set")
    }

    func testInterruptClear() {
        let uart = PL011UART()
        uart.injectCharacter(0x41)

        // Verify RX interrupt is set.
        let risBefore = uart.mmioRead(offset: 0x03C, size: 4)
        XCTAssertNotEqual(risBefore & UInt64(1 << 4), 0)

        // Clear RX interrupt.
        uart.mmioWrite(offset: 0x044, size: 4, value: UInt64(1 << 4))

        let risAfter = uart.mmioRead(offset: 0x03C, size: 4)
        XCTAssertEqual(risAfter & UInt64(1 << 4), 0, "RXIS should be cleared after ICR write")
    }

    // MARK: - Control Register

    func testControlRegisterReadWrite() {
        let uart = PL011UART()
        uart.mmioWrite(offset: 0x030, size: 4, value: 0x301)
        let cr = uart.mmioRead(offset: 0x030, size: 4)
        XCTAssertEqual(cr & 0x301, 0x301)
    }

    func testBaudRateRegisters() {
        let uart = PL011UART()
        uart.mmioWrite(offset: 0x024, size: 4, value: 0x0027) // IBRD
        uart.mmioWrite(offset: 0x028, size: 4, value: 0x04)   // FBRD

        XCTAssertEqual(uart.mmioRead(offset: 0x024, size: 4), 0x0027)
        XCTAssertEqual(uart.mmioRead(offset: 0x028, size: 4), 0x04)
    }

    // MARK: - Reset

    func testResetClearsState() {
        let uart = PL011UART()
        uart.injectCharacter(0x41)
        uart.mmioWrite(offset: 0x038, size: 4, value: 0xFF)  // Set interrupt mask
        uart.mmioWrite(offset: 0x024, size: 4, value: 0x27)  // Set baud rate

        uart.reset()

        // RX FIFO should be empty.
        let flags = UInt32(uart.mmioRead(offset: 0x018, size: 4))
        XCTAssertNotEqual(flags & (1 << 4), 0, "RXFE should be set after reset")

        // Interrupt mask should be cleared.
        XCTAssertEqual(uart.mmioRead(offset: 0x038, size: 4), 0)

        // Baud rate should be cleared.
        XCTAssertEqual(uart.mmioRead(offset: 0x024, size: 4), 0)
    }

    // MARK: - Unknown Register Access

    func testUnknownOffsetReturnsZero() {
        let uart = PL011UART()
        XCTAssertEqual(uart.mmioRead(offset: 0x100, size: 4), 0)
    }
}

// MARK: - PL031 RTC Tests

final class PL031RTCTests: XCTestCase {

    // MARK: - Initialization

    func testDefaultBaseAddress() {
        let rtc = PL031RTC()
        XCTAssertEqual(rtc.baseAddress, MachineMemoryMap.rtcBase)
        XCTAssertEqual(rtc.regionSize, MachineMemoryMap.rtcSize)
    }

    // MARK: - PrimeCell ID Registers

    func testPrimeCellIDRegisters() {
        let rtc = PL031RTC()

        XCTAssertEqual(rtc.mmioRead(offset: 0xFE0, size: 4), 0x31)
        XCTAssertEqual(rtc.mmioRead(offset: 0xFE4, size: 4), 0x10)
        XCTAssertEqual(rtc.mmioRead(offset: 0xFE8, size: 4), 0x04)
        XCTAssertEqual(rtc.mmioRead(offset: 0xFEC, size: 4), 0x00)

        XCTAssertEqual(rtc.mmioRead(offset: 0xFF0, size: 4), 0x0D)
        XCTAssertEqual(rtc.mmioRead(offset: 0xFF4, size: 4), 0xF0)
        XCTAssertEqual(rtc.mmioRead(offset: 0xFF8, size: 4), 0x05)
        XCTAssertEqual(rtc.mmioRead(offset: 0xFFC, size: 4), 0xB1)
    }

    // MARK: - Time Reading

    func testDataRegisterReturnsTime() {
        let fixedTime: TimeInterval = 1_700_000_000 // A known epoch time
        let rtc = PL031RTC(timeSource: { fixedTime })

        let dr = UInt32(rtc.mmioRead(offset: 0x000, size: 4))
        XCTAssertEqual(dr, UInt32(fixedTime))
    }

    func testTimeAdvances() {
        var currentTime: TimeInterval = 1_700_000_000
        let rtc = PL031RTC(timeSource: { currentTime })

        let t1 = UInt32(rtc.mmioRead(offset: 0x000, size: 4))

        // Advance host time by 60 seconds.
        currentTime += 60

        let t2 = UInt32(rtc.mmioRead(offset: 0x000, size: 4))
        XCTAssertEqual(t2 - t1, 60)
    }

    // MARK: - Load Register

    func testLoadRegisterSetsCounter() {
        var currentTime: TimeInterval = 1_700_000_000
        let rtc = PL031RTC(timeSource: { currentTime })

        // Set the counter to a specific value.
        let loadValue: UInt64 = 1_000_000
        rtc.mmioWrite(offset: 0x008, size: 4, value: loadValue)

        // Immediately read -- should be close to the loaded value.
        let dr = UInt32(rtc.mmioRead(offset: 0x000, size: 4))
        XCTAssertEqual(dr, UInt32(loadValue))

        // Advance time by 10 seconds.
        currentTime += 10
        let dr2 = UInt32(rtc.mmioRead(offset: 0x000, size: 4))
        XCTAssertEqual(dr2, UInt32(loadValue) + 10)
    }

    // MARK: - Match Register

    func testMatchRegisterReadWrite() {
        let rtc = PL031RTC()
        rtc.mmioWrite(offset: 0x004, size: 4, value: 0xDEAD_BEEF)

        let mr = rtc.mmioRead(offset: 0x004, size: 4)
        XCTAssertEqual(mr, 0xDEAD_BEEF)
    }

    // MARK: - Interrupt Handling

    func testMatchInterrupt() {
        let fixedTime: TimeInterval = 1000
        let rtc = PL031RTC(timeSource: { fixedTime })

        // Load counter to 1000.
        rtc.mmioWrite(offset: 0x008, size: 4, value: 1000)

        // Set match to 1000 (current time).
        rtc.mmioWrite(offset: 0x004, size: 4, value: 1000)

        var interruptAsserted = false
        rtc.onInterruptStateChanged = { active in
            interruptAsserted = active
        }

        // Enable interrupt mask.
        rtc.mmioWrite(offset: 0x010, size: 4, value: 1)

        // Check match -- should fire.
        rtc.checkMatchInterrupt()
        XCTAssertTrue(interruptAsserted)

        // Raw interrupt status should be set.
        let ris = rtc.mmioRead(offset: 0x014, size: 4)
        XCTAssertEqual(ris & 1, 1)

        // Clear the interrupt.
        rtc.mmioWrite(offset: 0x01C, size: 4, value: 1)
        let risAfter = rtc.mmioRead(offset: 0x014, size: 4)
        XCTAssertEqual(risAfter & 1, 0)
    }

    // MARK: - Control Register

    func testControlRegisterAlwaysHasBit0Set() {
        let rtc = PL031RTC()

        // Try to clear bit 0 -- should stay set.
        rtc.mmioWrite(offset: 0x00C, size: 4, value: 0)
        let cr = rtc.mmioRead(offset: 0x00C, size: 4)
        XCTAssertEqual(cr & 1, 1, "RTC enable bit cannot be cleared once set")
    }

    // MARK: - Reset

    func testResetResetsState() {
        var currentTime: TimeInterval = 1_700_000_000
        let rtc = PL031RTC(timeSource: { currentTime })

        rtc.mmioWrite(offset: 0x004, size: 4, value: 0x1234)
        rtc.mmioWrite(offset: 0x010, size: 4, value: 1)

        rtc.reset()

        // Match register should be cleared.
        XCTAssertEqual(rtc.mmioRead(offset: 0x004, size: 4), 0)
        // Interrupt mask should be cleared.
        XCTAssertEqual(rtc.mmioRead(offset: 0x010, size: 4), 0)
        // Counter should be re-initialized from host time.
        let dr = UInt32(rtc.mmioRead(offset: 0x000, size: 4))
        XCTAssertEqual(dr, UInt32(currentTime))
    }
}

// MARK: - Flash Device Tests

final class FlashDeviceTests: XCTestCase {

    /// Helper: create a flash device with known data.
    private func makeFlash(
        firmwareData: Data? = nil,
        varsData: Data? = nil,
        bankSize: Int = 4096,
        blockSize: Int = 1024
    ) -> FlashDevice {
        let firmware = firmwareData ?? Data(repeating: 0xAB, count: bankSize)
        return FlashDevice(
            baseAddress: 0x0,
            firmwareData: firmware,
            varsData: varsData,
            bankSize: bankSize,
            blockSize: blockSize
        )
    }

    // MARK: - Read Array Mode

    func testReadCodeBankArray() {
        let firmware = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let flash = makeFlash(firmwareData: firmware)

        // Read first 4 bytes from CODE bank.
        let b0 = flash.mmioRead(offset: 0, size: 1)
        let b1 = flash.mmioRead(offset: 1, size: 1)
        let b2 = flash.mmioRead(offset: 2, size: 1)
        let b3 = flash.mmioRead(offset: 3, size: 1)

        XCTAssertEqual(b0, 0xDE)
        XCTAssertEqual(b1, 0xAD)
        XCTAssertEqual(b2, 0xBE)
        XCTAssertEqual(b3, 0xEF)
    }

    func testReadVarsBankInitiallyErased() {
        let flash = makeFlash()

        // VARS bank starts at offset bankSize (4096). Should be all 0xFF.
        let value = flash.mmioRead(offset: 4096, size: 4)
        XCTAssertEqual(value, 0xFFFF_FFFF)
    }

    func testReadVarsBankWith32BitWidth() {
        var vars = Data(repeating: 0xFF, count: 4096)
        vars[0] = 0x12
        vars[1] = 0x34
        vars[2] = 0x56
        vars[3] = 0x78
        let flash = makeFlash(varsData: vars)

        let value = flash.mmioRead(offset: 4096, size: 4)
        // Little-endian: 0x78_56_34_12
        XCTAssertEqual(value, 0x7856_3412)
    }

    // MARK: - CFI Query Mode

    func testCFIQueryMode() {
        let flash = makeFlash()

        // Enter CFI query mode by writing 0x98.
        flash.mmioWrite(offset: 0, size: 1, value: 0x98)

        // Read "QRY" at word offsets 0x10, 0x11, 0x12 (byte offsets 0x20, 0x22, 0x24).
        let q = flash.mmioRead(offset: 0x20, size: 1) // word 0x10
        let r = flash.mmioRead(offset: 0x22, size: 1) // word 0x11
        let y = flash.mmioRead(offset: 0x24, size: 1) // word 0x12

        XCTAssertEqual(q, 0x51, "Expected 'Q' (0x51)")
        XCTAssertEqual(r, 0x52, "Expected 'R' (0x52)")
        XCTAssertEqual(y, 0x59, "Expected 'Y' (0x59)")
    }

    func testCFIQueryReturnsIntelCommandSet() {
        let flash = makeFlash()
        flash.mmioWrite(offset: 0, size: 1, value: 0x98)

        // Primary vendor command set at word offset 0x13 (byte offset 0x26).
        let vendorLow = flash.mmioRead(offset: 0x26, size: 1)
        XCTAssertEqual(vendorLow, 0x01, "Expected Intel/Sharp command set (0x0001)")
    }

    func testResetExitsCFIQuery() {
        let flash = makeFlash()

        // Enter CFI query.
        flash.mmioWrite(offset: 0, size: 1, value: 0x98)

        // Reset to read-array mode.
        flash.mmioWrite(offset: 0, size: 1, value: 0xFF)

        // Should read firmware data, not CFI.
        let firmware = Data(repeating: 0xAB, count: 4096)
        let value = flash.mmioRead(offset: 0, size: 1)
        XCTAssertEqual(value, UInt64(firmware[0]))
    }

    // MARK: - Word Program

    func testWordProgramOnVarsBank() {
        let flash = makeFlash()
        let varsOffset: UInt64 = 4096 // VARS bank start

        // Issue program command (0x40) then write data.
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x40)
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0xA5)

        // Reset to read-array mode to read back.
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0xFF)

        let value = flash.mmioRead(offset: varsOffset, size: 1)
        // NOR flash: 0xFF & 0xA5 = 0xA5
        XCTAssertEqual(value, 0xA5)
    }

    func testWordProgramCanOnlyClearBits() {
        var vars = Data(repeating: 0xFF, count: 4096)
        vars[0] = 0xF0 // Start with 0xF0
        let flash = makeFlash(varsData: vars)
        let varsOffset: UInt64 = 4096

        // Try to program 0x0F (attempt to set bits 0-3, clear bits 4-7).
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x40)
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x0F)
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0xFF)

        let value = flash.mmioRead(offset: varsOffset, size: 1)
        // 0xF0 & 0x0F = 0x00 -- NOR flash can only clear bits.
        XCTAssertEqual(value, 0x00)
    }

    func testWordProgramOnCodeBankFails() {
        let flash = makeFlash()

        // Try to program the CODE bank (read-only).
        flash.mmioWrite(offset: 0, size: 1, value: 0x40)

        // Should go to read-status with program error.
        let status = flash.mmioRead(offset: 0, size: 1)
        XCTAssertNotEqual(status & UInt64(1 << 4), 0, "Program error bit should be set")
    }

    // MARK: - Block Erase

    func testBlockErase() {
        var vars = Data(repeating: 0x55, count: 4096)
        let flash = makeFlash(varsData: vars)
        let varsOffset: UInt64 = 4096

        // Block erase: setup (0x20) then confirm (0xD0).
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x20)
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0xD0)

        // Reset to read-array.
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0xFF)

        // First block (1024 bytes) should be erased to 0xFF.
        let value = flash.mmioRead(offset: varsOffset, size: 1)
        XCTAssertEqual(value, 0xFF)

        // Second block (offset 1024 from VARS start) should be untouched.
        let value2 = flash.mmioRead(offset: varsOffset + 1024, size: 1)
        XCTAssertEqual(value2, 0x55)
    }

    func testBlockEraseAbortOnWrongConfirm() {
        let flash = makeFlash()
        let varsOffset: UInt64 = 4096

        // Block erase setup.
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x20)
        // Send wrong confirm byte.
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0xAA)

        // Should report erase error.
        let status = flash.mmioRead(offset: varsOffset, size: 1)
        XCTAssertNotEqual(status & UInt64(1 << 5), 0, "Erase error bit should be set")
    }

    // MARK: - Status Register

    func testStatusRegisterReadReady() {
        let flash = makeFlash()

        // Enter status read mode.
        flash.mmioWrite(offset: 0, size: 1, value: 0x70)

        let status = flash.mmioRead(offset: 0, size: 1)
        XCTAssertNotEqual(status & UInt64(1 << 7), 0, "Ready bit should be set")
    }

    func testClearStatusRegister() {
        let flash = makeFlash()

        // Trigger a program error on read-only bank.
        flash.mmioWrite(offset: 0, size: 1, value: 0x40)

        // Clear status.
        flash.mmioWrite(offset: 0, size: 1, value: 0x50)

        // Should be back in read-array mode. Read firmware data.
        let value = flash.mmioRead(offset: 0, size: 1)
        XCTAssertEqual(value, 0xAB, "Should read firmware data after status clear")
    }

    // MARK: - Read Electronic Signature

    func testReadElectronicSignature() {
        let flash = makeFlash()

        flash.mmioWrite(offset: 0, size: 1, value: 0x90)

        // Manufacturer code at word address 0 (byte offset 0).
        let manufacturer = flash.mmioRead(offset: 0, size: 1)
        XCTAssertEqual(manufacturer, 0x89, "Expected Intel manufacturer code")

        // Device code at word address 1 (byte offset 2).
        let device = flash.mmioRead(offset: 2, size: 1)
        XCTAssertEqual(device, 0x18)
    }

    // MARK: - Dirty Tracking

    func testDirtyFlagAfterProgram() {
        let flash = makeFlash()
        XCTAssertFalse(flash.isDirty)

        let varsOffset: UInt64 = 4096
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x40)
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x55)

        XCTAssertTrue(flash.isDirty)
    }

    // MARK: - Persistence

    func testFlushWritesToDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let varsURL = tempDir.appendingPathComponent("test_vars_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: varsURL) }

        let flash = FlashDevice(
            baseAddress: 0,
            firmwareData: Data(repeating: 0xAB, count: 4096),
            varsData: nil,
            varsFileURL: varsURL,
            bankSize: 4096,
            blockSize: 1024
        )

        let varsOffset: UInt64 = 4096
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0x40)
        flash.mmioWrite(offset: varsOffset, size: 1, value: 0xBE)

        try flash.flush()

        let written = try Data(contentsOf: varsURL)
        XCTAssertEqual(written.count, 4096)
        // First byte should be 0xFF & 0xBE = 0xBE.
        XCTAssertEqual(written[0], 0xBE)
        XCTAssertFalse(flash.isDirty)
    }

    // MARK: - Reset

    func testResetReturnsBanksToReadArray() {
        let flash = makeFlash()

        // Enter CFI query mode.
        flash.mmioWrite(offset: 0, size: 1, value: 0x98)

        flash.reset()

        // Should be back in read-array mode.
        let value = flash.mmioRead(offset: 0, size: 1)
        XCTAssertEqual(value, 0xAB)
    }
}

// MARK: - Power Controller Tests

final class PowerControllerTests: XCTestCase {

    // MARK: - Initialization

    func testInitialCPUStates() {
        let psci = PowerController(cpuCount: 4)

        XCTAssertEqual(psci.cpuState(for: 0), .on, "Boot CPU should start on")
        XCTAssertEqual(psci.cpuState(for: 1), .off)
        XCTAssertEqual(psci.cpuState(for: 2), .off)
        XCTAssertEqual(psci.cpuState(for: 3), .off)
    }

    func testOutOfRangeCPUStateReturnsNil() {
        let psci = PowerController(cpuCount: 2)
        XCTAssertNil(psci.cpuState(for: 5))
        XCTAssertNil(psci.cpuState(for: -1))
    }

    // MARK: - PSCI_VERSION

    func testPSCIVersion() {
        let psci = PowerController(cpuCount: 1)
        let result = psci.handleCall(
            functionID: PSCIFunctionID.version.rawValue,
            x1: 0, x2: 0, x3: 0, callerCPU: 0
        )

        // PSCI v1.1 = 0x0001_0001
        XCTAssertEqual(result.x0Value, UInt64(psciVersionValue))
        XCTAssertTrue(result.continueExecution)
    }

    // MARK: - CPU_ON

    func testCPUOnSuccess() {
        let psci = PowerController(cpuCount: 4)
        var receivedEvent: PSCIEvent?
        psci.onEvent = { event in
            receivedEvent = event
        }

        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn64.rawValue,
            x1: 1,             // target CPU 1
            x2: 0x4008_0000,   // entry point
            x3: 0xCAFE,        // context ID
            callerCPU: 0
        )

        XCTAssertEqual(result.returnValue, PSCIReturn.success)
        XCTAssertTrue(result.continueExecution)

        // CPU 1 should now be onPending.
        XCTAssertEqual(psci.cpuState(for: 1), .onPending)

        // Event should have been emitted.
        if case .cpuOn(let cpuID, let entry, let ctx) = receivedEvent {
            XCTAssertEqual(cpuID, 1)
            XCTAssertEqual(entry, 0x4008_0000)
            XCTAssertEqual(ctx, 0xCAFE)
        } else {
            XCTFail("Expected .cpuOn event, got \(String(describing: receivedEvent))")
        }
    }

    func testCPUOnAlreadyOn() {
        let psci = PowerController(cpuCount: 2)
        // CPU 0 is already on.
        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn64.rawValue,
            x1: 0, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result.returnValue, PSCIReturn.alreadyOn)
    }

    func testCPUOnInvalidCPU() {
        let psci = PowerController(cpuCount: 2)
        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn64.rawValue,
            x1: 99, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result.returnValue, PSCIReturn.invalidParameters)
    }

    func testCPUOnPending() {
        let psci = PowerController(cpuCount: 2)
        // First CPU_ON succeeds.
        _ = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn64.rawValue,
            x1: 1, x2: 0, x3: 0, callerCPU: 0
        )
        // Second CPU_ON for same CPU returns ON_PENDING.
        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn64.rawValue,
            x1: 1, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result.returnValue, PSCIReturn.onPending)
    }

    // MARK: - CPU_OFF

    func testCPUOff() {
        let psci = PowerController(cpuCount: 2)
        var receivedEvent: PSCIEvent?
        psci.onEvent = { event in
            receivedEvent = event
        }

        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuOff.rawValue,
            x1: 0, x2: 0, x3: 0, callerCPU: 0
        )

        XCTAssertEqual(result.returnValue, PSCIReturn.success)
        XCTAssertFalse(result.continueExecution, "CPU_OFF should halt the vCPU")
        XCTAssertEqual(psci.cpuState(for: 0), .off)

        if case .cpuOff(let cpuID) = receivedEvent {
            XCTAssertEqual(cpuID, 0)
        } else {
            XCTFail("Expected .cpuOff event")
        }
    }

    // MARK: - SYSTEM_OFF

    func testSystemOff() {
        let psci = PowerController(cpuCount: 2)
        var receivedEvent: PSCIEvent?
        psci.onEvent = { event in
            receivedEvent = event
        }

        let result = psci.handleCall(
            functionID: PSCIFunctionID.systemOff.rawValue,
            x1: 0, x2: 0, x3: 0, callerCPU: 0
        )

        XCTAssertFalse(result.continueExecution)
        if case .systemOff = receivedEvent {
            // Expected
        } else {
            XCTFail("Expected .systemOff event")
        }
    }

    // MARK: - SYSTEM_RESET

    func testSystemReset() {
        let psci = PowerController(cpuCount: 1)
        var receivedEvent: PSCIEvent?
        psci.onEvent = { event in
            receivedEvent = event
        }

        let result = psci.handleCall(
            functionID: PSCIFunctionID.systemReset.rawValue,
            x1: 0, x2: 0, x3: 0, callerCPU: 0
        )

        XCTAssertFalse(result.continueExecution)
        if case .systemReset = receivedEvent {
            // Expected
        } else {
            XCTFail("Expected .systemReset event")
        }
    }

    // MARK: - AFFINITY_INFO

    func testAffinityInfo() {
        let psci = PowerController(cpuCount: 3)

        // CPU 0 is on.
        let result0 = psci.handleCall(
            functionID: PSCIFunctionID.affinityInfo64.rawValue,
            x1: 0, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result0.returnValue, 0, "CPU 0 should be ON (0)")

        // CPU 1 is off.
        let result1 = psci.handleCall(
            functionID: PSCIFunctionID.affinityInfo64.rawValue,
            x1: 1, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result1.returnValue, 1, "CPU 1 should be OFF (1)")

        // Power on CPU 2 -- should be ON_PENDING.
        _ = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn64.rawValue,
            x1: 2, x2: 0, x3: 0, callerCPU: 0
        )
        let result2 = psci.handleCall(
            functionID: PSCIFunctionID.affinityInfo64.rawValue,
            x1: 2, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result2.returnValue, 2, "CPU 2 should be ON_PENDING (2)")
    }

    // MARK: - PSCI_FEATURES

    func testFeaturesSupported() {
        let psci = PowerController(cpuCount: 1)

        // PSCI_VERSION should be supported.
        let versionResult = psci.handleCall(
            functionID: PSCIFunctionID.features.rawValue,
            x1: UInt64(PSCIFunctionID.version.rawValue),
            x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(versionResult.returnValue, PSCIReturn.success)

        // CPU_ON should be supported.
        let cpuOnResult = psci.handleCall(
            functionID: PSCIFunctionID.features.rawValue,
            x1: UInt64(PSCIFunctionID.cpuOn64.rawValue),
            x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(cpuOnResult.returnValue, PSCIReturn.success)
    }

    func testFeaturesUnsupported() {
        let psci = PowerController(cpuCount: 1)

        // Random function ID should be not supported.
        let result = psci.handleCall(
            functionID: PSCIFunctionID.features.rawValue,
            x1: 0xDEAD_BEEF,
            x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result.returnValue, PSCIReturn.notSupported)
    }

    // MARK: - Unknown Function

    func testUnknownFunctionReturnsNotSupported() {
        let psci = PowerController(cpuCount: 1)

        let result = psci.handleCall(
            functionID: 0xFFFF_FFFF,
            x1: 0, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result.returnValue, PSCIReturn.notSupported)
        XCTAssertTrue(result.continueExecution)
    }

    // MARK: - State Management

    func testMarkCPUOn() {
        let psci = PowerController(cpuCount: 2)
        // Start CPU_ON flow.
        _ = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn64.rawValue,
            x1: 1, x2: 0, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(psci.cpuState(for: 1), .onPending)

        // Mark it as actually on.
        psci.markCPUOn(1)
        XCTAssertEqual(psci.cpuState(for: 1), .on)
    }

    func testReset() {
        let psci = PowerController(cpuCount: 3)
        psci.markCPUOn(1)
        psci.markCPUOn(2)

        psci.reset()

        XCTAssertEqual(psci.cpuState(for: 0), .on)
        XCTAssertEqual(psci.cpuState(for: 1), .off)
        XCTAssertEqual(psci.cpuState(for: 2), .off)
    }

    // MARK: - CPU_SUSPEND

    func testCPUSuspendStandby() {
        let psci = PowerController(cpuCount: 1)
        var receivedEvent: PSCIEvent?
        psci.onEvent = { event in
            receivedEvent = event
        }

        // Standby suspend (bit 16 = 0).
        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuSuspend64.rawValue,
            x1: 0x0000_0000,   // power state: standby
            x2: 0x4008_0000,   // entry point
            x3: 0,
            callerCPU: 0
        )

        XCTAssertEqual(result.returnValue, PSCIReturn.success)
        XCTAssertTrue(result.continueExecution, "Standby suspend should continue execution")

        if case .cpuSuspend(let cpuID, _, _) = receivedEvent {
            XCTAssertEqual(cpuID, 0)
        } else {
            XCTFail("Expected .cpuSuspend event")
        }
    }

    func testCPUSuspendPowerDown() {
        let psci = PowerController(cpuCount: 1)

        // Power-down suspend (bit 16 = 1).
        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuSuspend64.rawValue,
            x1: UInt64(1 << 16), // power state: power-down
            x2: 0x4008_0000,
            x3: 0,
            callerCPU: 0
        )

        XCTAssertEqual(result.returnValue, PSCIReturn.success)
        XCTAssertFalse(result.continueExecution, "Power-down suspend should halt the vCPU")
    }

    // MARK: - 32-bit Calling Convention

    func testCPUOn32Bit() {
        let psci = PowerController(cpuCount: 2)
        let result = psci.handleCall(
            functionID: PSCIFunctionID.cpuOn32.rawValue,
            x1: 1, x2: 0x4000_0000, x3: 0, callerCPU: 0
        )
        XCTAssertEqual(result.returnValue, PSCIReturn.success)
        XCTAssertEqual(psci.cpuState(for: 1), .onPending)
    }

    // MARK: - x0Value Sign Extension

    func testX0ValueSignExtension() {
        let result = PSCICallResult(returnValue: PSCIReturn.notSupported, continueExecution: true)
        // -1 sign extended to 64 bits.
        XCTAssertEqual(result.x0Value, UInt64(bitPattern: -1))
    }

    func testX0ValuePositive() {
        let result = PSCICallResult(returnValue: PSCIReturn.success, continueExecution: true)
        XCTAssertEqual(result.x0Value, 0)
    }
}
#endif // canImport(XCTest)
