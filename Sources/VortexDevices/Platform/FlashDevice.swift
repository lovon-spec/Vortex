// FlashDevice.swift -- CFI NOR flash emulation for UEFI variable store.
// VortexDevices
//
// Emulates a pair of CFI-compliant NOR flash banks:
//   - Bank 0 (CODE): Read-only firmware image.
//   - Bank 1 (VARS): Read-write variable store, backed by a file on the host.
//
// This is the storage backend for UEFI NVRAM variables. EDK2 firmware writes
// variables to the VARS bank using standard CFI flash commands. The VMM
// persists these writes to a file on the host filesystem.
//
// Supported CFI flash operations:
//   - Read Array (normal read)
//   - CFI Query (0x98 at offset 0x55)
//   - Word Program (0x40 / 0x10)
//   - Block Erase (0x20 + 0xD0 confirm)
//   - Status Register Read (0x70)
//   - Clear Status Register (0x50)
//   - Read Electronic Signature (0x90)
//   - Reset / Read Array (0xFF)
//
// The emulated flash is Intel-compatible (CFI vendor command set 0x0001).

import Foundation
import VortexHV

// MARK: - Flash State Machine

/// CFI flash command state machine states.
private enum FlashState {
    /// Normal read mode -- reads return flash contents.
    case readArray
    /// CFI query mode -- reads return CFI structure data.
    case cfiQuery
    /// Waiting for data byte after a program command (0x40 or 0x10).
    case programming
    /// Waiting for erase confirm (0xD0) after block erase setup (0x20).
    case eraseSetup(blockOffset: Int)
    /// Status register read mode.
    case readStatus
    /// Read electronic signature / device ID mode.
    case readID
}

// MARK: - Flash Status Register

/// CFI flash status register bits.
private enum FlashStatus {
    static let ready: UInt8       = 1 << 7  // Device ready
    static let eraseSuspend: UInt8 = 1 << 6  // Erase suspend
    static let eraseError: UInt8  = 1 << 5  // Erase error
    static let programError: UInt8 = 1 << 4  // Program error
    static let vpError: UInt8     = 1 << 3  // Vpp range error
    static let programSuspend: UInt8 = 1 << 2 // Program suspend
    static let locked: UInt8      = 1 << 1  // Block locked error
}

// MARK: - CFI Query Data

/// Build the standard CFI query table for an Intel-compatible NOR flash.
///
/// The CFI (Common Flash Interface) query structure is read by firmware
/// to discover flash geometry, erase block sizes, and timing parameters.
///
/// - Parameters:
///   - bankSize: Total size of the flash bank in bytes.
///   - blockSize: Erase block size in bytes.
/// - Returns: CFI query response data, indexed from offset 0x10 (word address).
private func buildCFIQueryData(bankSize: Int, blockSize: Int) -> [UInt8] {
    // CFI query data starts at word-address 0x10 (byte-address 0x20 for 16-bit).
    // We build it from byte-offset 0 in this array; the caller adjusts addressing.
    var data = [UInt8](repeating: 0, count: 256)

    // Query-unique ASCII string "QRY" at offsets 0x10, 0x11, 0x12
    let qryBase = 0x10
    data[qryBase + 0] = 0x51  // 'Q'
    data[qryBase + 1] = 0x52  // 'R'
    data[qryBase + 2] = 0x59  // 'Y'

    // Primary vendor command set: Intel/Sharp Extended (0x0001)
    data[qryBase + 3] = 0x01  // Primary algorithm command set (low)
    data[qryBase + 4] = 0x00  // Primary algorithm command set (high)

    // Primary algorithm extended query table address
    data[qryBase + 5] = 0x00
    data[qryBase + 6] = 0x00

    // Alternate vendor command set: none (0x0000)
    data[qryBase + 7] = 0x00
    data[qryBase + 8] = 0x00

    // Alternate algorithm extended query table address
    data[qryBase + 9] = 0x00
    data[qryBase + 10] = 0x00

    // System interface information
    data[qryBase + 11] = 0x45 // Vcc min (4.5V encoded as BCD: 0x45)
    data[qryBase + 12] = 0x55 // Vcc max (5.5V encoded as BCD: 0x55)
    data[qryBase + 13] = 0x00 // Vpp min (not used)
    data[qryBase + 14] = 0x00 // Vpp max (not used)

    // Typical timeouts (log2 microseconds)
    data[qryBase + 15] = 0x04 // Typical single word program: 16 us (2^4)
    data[qryBase + 16] = 0x00 // Typical max buffer write: N/A
    data[qryBase + 17] = 0x0A // Typical block erase: 1024 us (2^10)
    data[qryBase + 18] = 0x00 // Typical full chip erase: N/A

    // Maximum timeouts (multiplied by 2^N from typical)
    data[qryBase + 19] = 0x04 // Max single word program: 256 us
    data[qryBase + 20] = 0x00 // Max buffer write: N/A
    data[qryBase + 21] = 0x04 // Max block erase: 16384 us
    data[qryBase + 22] = 0x00 // Max full chip erase: N/A

    // Device geometry
    let deviceSizeLog2 = UInt8(log2(Double(bankSize)))
    data[qryBase + 23] = deviceSizeLog2 // Device size = 2^N bytes

    data[qryBase + 24] = 0x01 // Flash device interface: x16
    data[qryBase + 25] = 0x00

    // Max bytes in multi-byte program = 0 (no buffer write)
    data[qryBase + 26] = 0x00
    data[qryBase + 27] = 0x00

    // Number of erase block regions
    data[qryBase + 28] = 0x01

    // Erase block region 1 info (4 bytes)
    let numBlocks = bankSize / blockSize
    let blocksMinusOne = UInt16(numBlocks - 1)
    data[qryBase + 29] = UInt8(blocksMinusOne & 0xFF)
    data[qryBase + 30] = UInt8((blocksMinusOne >> 8) & 0xFF)

    // Block size in 256-byte units
    let blockSize256 = UInt16(blockSize / 256)
    data[qryBase + 31] = UInt8(blockSize256 & 0xFF)
    data[qryBase + 32] = UInt8((blockSize256 >> 8) & 0xFF)

    return data
}

// MARK: - Flash Bank

/// A single bank of CFI NOR flash (either CODE or VARS).
///
/// Thread safety: All access must be serialized externally by the owning
/// `FlashDevice` instance's lock.
private final class FlashBank {
    /// The flash contents. For a writable bank, this is mutated in place.
    var data: Data

    /// Whether this bank is writable (VARS) or read-only (CODE).
    let writable: Bool

    /// Erase block size in bytes (typically 256 KB).
    let blockSize: Int

    /// Pre-computed CFI query response data for this bank.
    let cfiData: [UInt8]

    /// Status register.
    var status: UInt8 = FlashStatus.ready

    /// Command state machine.
    var state: FlashState = .readArray

    init(data: Data, writable: Bool, blockSize: Int) {
        self.data = data
        self.writable = writable
        self.blockSize = blockSize
        self.cfiData = buildCFIQueryData(bankSize: data.count, blockSize: blockSize)
    }

    /// Reset the bank to read-array mode.
    func resetState() {
        state = .readArray
        status = FlashStatus.ready
    }
}

// MARK: - Flash Device

/// CFI NOR flash device emulation implementing the MMIODevice protocol.
///
/// Presents two flash banks at consecutive regions in guest physical memory:
///   - Bank 0 (CODE): Contains the firmware image. Read-only.
///   - Bank 1 (VARS): Contains UEFI NVRAM variables. Read-write, backed by a host file.
///
/// The guest firmware (EDK2) discovers the flash geometry via CFI Query and
/// uses Intel-compatible commands to program and erase the VARS bank.
///
/// ## Persistence
/// When the guest writes to the VARS bank, changes are accumulated in memory.
/// Call ``flush()`` to write the current VARS contents to disk. The caller is
/// responsible for flushing at appropriate times (VM shutdown, periodic save).
///
/// ## Threading Model
/// - `mmioRead`/`mmioWrite` are called from the vCPU thread.
/// - `flush()` may be called from any thread.
public final class FlashDevice: MMIODevice, @unchecked Sendable {

    // MARK: - MMIODevice Properties

    public let baseAddress: UInt64
    public let regionSize: UInt64

    // MARK: - Configuration

    /// Default erase block size: 256 KB (matching common NOR flash geometry).
    public static let defaultBlockSize = 256 * 1024

    /// Default bank size: 64 MB each (128 MB total).
    public static let defaultBankSize = 64 * 1024 * 1024

    // MARK: - Internal State

    private let lock = NSLock()
    private let codeBank: FlashBank
    private let varsBank: FlashBank

    /// Size of each individual bank.
    public let bankSize: Int

    /// The file URL for the VARS bank persistence.
    private let varsFileURL: URL?

    /// Whether the VARS bank has been modified since last flush.
    private var varsDirty = false

    // MARK: - Initialization

    /// Create a flash device with the given firmware and variable store data.
    ///
    /// - Parameters:
    ///   - baseAddress: The MMIO base address for the flash region.
    ///   - firmwareData: The firmware (CODE bank) contents. Padded or truncated
    ///     to `bankSize`. This bank is read-only.
    ///   - varsData: The initial NVRAM variable store contents. If `nil`, the
    ///     VARS bank is initialized to all 0xFF (erased flash). Padded or truncated
    ///     to `bankSize`.
    ///   - varsFileURL: Path to persist the VARS bank. If `nil`, changes are
    ///     not persisted to disk.
    ///   - bankSize: Size of each bank in bytes. Both banks are the same size.
    ///   - blockSize: Erase block size in bytes.
    public init(
        baseAddress: UInt64,
        firmwareData: Data,
        varsData: Data? = nil,
        varsFileURL: URL? = nil,
        bankSize: Int = FlashDevice.defaultBankSize,
        blockSize: Int = FlashDevice.defaultBlockSize
    ) {
        self.baseAddress = baseAddress
        self.bankSize = bankSize
        self.regionSize = UInt64(bankSize * 2)
        self.varsFileURL = varsFileURL

        // Prepare CODE bank: pad firmware to bankSize, read-only.
        var code = firmwareData
        if code.count < bankSize {
            code.append(Data(repeating: 0xFF, count: bankSize - code.count))
        } else if code.count > bankSize {
            code = code.prefix(bankSize)
        }
        self.codeBank = FlashBank(data: code, writable: false, blockSize: blockSize)

        // Prepare VARS bank: use provided data or erased flash.
        var vars: Data
        if let existing = varsData {
            vars = existing
        } else {
            vars = Data(repeating: 0xFF, count: bankSize)
        }
        if vars.count < bankSize {
            vars.append(Data(repeating: 0xFF, count: bankSize - vars.count))
        } else if vars.count > bankSize {
            vars = vars.prefix(bankSize)
        }
        self.varsBank = FlashBank(data: vars, writable: true, blockSize: blockSize)
    }

    /// Create a flash device by loading firmware and variable store from files.
    ///
    /// - Parameters:
    ///   - baseAddress: The MMIO base address for the flash region.
    ///   - firmwareURL: Path to the firmware binary (CODE bank).
    ///   - varsFileURL: Path to the variable store file (VARS bank).
    ///     If the file does not exist, an empty (erased) VARS bank is created.
    ///   - bankSize: Size of each bank in bytes.
    ///   - blockSize: Erase block size in bytes.
    /// - Throws: If the firmware file cannot be read.
    public convenience init(
        baseAddress: UInt64,
        firmwareURL: URL,
        varsFileURL: URL,
        bankSize: Int = FlashDevice.defaultBankSize,
        blockSize: Int = FlashDevice.defaultBlockSize
    ) throws {
        let firmwareData = try Data(contentsOf: firmwareURL)
        let varsData: Data?
        if FileManager.default.fileExists(atPath: varsFileURL.path) {
            varsData = try Data(contentsOf: varsFileURL)
        } else {
            varsData = nil
        }
        self.init(
            baseAddress: baseAddress,
            firmwareData: firmwareData,
            varsData: varsData,
            varsFileURL: varsFileURL,
            bankSize: bankSize,
            blockSize: blockSize
        )
    }

    // MARK: - Persistence

    /// Flush the VARS bank contents to disk.
    ///
    /// This writes the entire VARS bank to the file specified at initialization.
    /// It is a no-op if no `varsFileURL` was provided or the bank has not been
    /// modified since the last flush.
    ///
    /// - Throws: If the file write fails.
    public func flush() throws {
        lock.lock()
        guard varsDirty, let url = varsFileURL else {
            lock.unlock()
            return
        }
        let data = varsBank.data
        varsDirty = false
        lock.unlock()

        try data.write(to: url, options: .atomic)
    }

    /// Whether the VARS bank has unsaved modifications.
    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return varsDirty
    }

    /// Reset both banks to read-array mode.
    public func reset() {
        lock.lock()
        codeBank.resetState()
        varsBank.resetState()
        lock.unlock()
    }

    // MARK: - MMIODevice Implementation

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        let (bank, bankOffset) = bankForOffset(offset)
        return readFromBank(bank, offset: bankOffset, size: size)
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let (bank, bankOffset) = bankForOffset(offset)
        writeToBank(bank, offset: bankOffset, size: size, value: value)
    }

    // MARK: - Private: Bank Selection

    /// Determine which bank an offset falls into and the offset within that bank.
    private func bankForOffset(_ offset: UInt64) -> (FlashBank, Int) {
        let intOffset = Int(offset)
        if intOffset < bankSize {
            return (codeBank, intOffset)
        } else {
            return (varsBank, intOffset - bankSize)
        }
    }

    // MARK: - Private: Read Logic

    private func readFromBank(_ bank: FlashBank, offset: Int, size: Int) -> UInt64 {
        switch bank.state {
        case .readArray:
            return readArrayData(bank, offset: offset, size: size)

        case .cfiQuery:
            return readCFIData(bank, offset: offset, size: size)

        case .readStatus, .programming, .eraseSetup:
            return UInt64(bank.status)

        case .readID:
            return readIDData(bank, offset: offset)
        }
    }

    /// Read raw flash data in read-array mode.
    private func readArrayData(_ bank: FlashBank, offset: Int, size: Int) -> UInt64 {
        guard offset >= 0, offset + size <= bank.data.count else {
            return 0
        }
        var result: UInt64 = 0
        bank.data.withUnsafeBytes { ptr in
            for i in 0..<size {
                let byte = ptr.load(fromByteOffset: offset + i, as: UInt8.self)
                result |= UInt64(byte) << (i * 8)
            }
        }
        return result
    }

    /// Read CFI query structure data.
    private func readCFIData(_ bank: FlashBank, offset: Int, size: Int) -> UInt64 {
        // CFI data is word-addressed. Convert byte offset to word index.
        let wordIndex = offset / 2
        guard wordIndex < bank.cfiData.count else {
            return 0
        }
        return UInt64(bank.cfiData[wordIndex])
    }

    /// Read electronic signature / device ID.
    private func readIDData(_ bank: FlashBank, offset: Int) -> UInt64 {
        // Word address 0: Manufacturer code (Intel = 0x89)
        // Word address 1: Device code
        let wordIndex = offset / 2
        switch wordIndex {
        case 0:
            return 0x89 // Intel manufacturer code
        case 1:
            return 0x18 // Device code (generic 128Mbit)
        case 2:
            return 0x00 // Block lock status (unlocked)
        default:
            return 0
        }
    }

    // MARK: - Private: Write Logic (Command Handling)

    private func writeToBank(_ bank: FlashBank, offset: Int, size: Int, value: UInt64) {
        let command = UInt8(truncatingIfNeeded: value)

        switch bank.state {
        case .readArray, .readStatus, .readID, .cfiQuery:
            handleCommand(bank, offset: offset, command: command)

        case .programming:
            executeProgramWord(bank, offset: offset, size: size, value: value)

        case .eraseSetup(let blockOffset):
            if command == 0xD0 {
                executeBlockErase(bank, blockOffset: blockOffset)
            } else {
                // Erase aborted -- any command other than confirm resets.
                bank.status |= FlashStatus.eraseError
                bank.state = .readStatus
            }
        }
    }

    /// Dispatch a flash command byte.
    private func handleCommand(_ bank: FlashBank, offset: Int, command: UInt8) {
        switch command {
        case 0xFF:
            // Reset / Read Array
            bank.state = .readArray
            bank.status = FlashStatus.ready

        case 0x98:
            // CFI Query
            bank.state = .cfiQuery

        case 0x40, 0x10:
            // Word Program (Setup)
            if bank.writable {
                bank.state = .programming
            } else {
                bank.status |= FlashStatus.programError
                bank.state = .readStatus
            }

        case 0x20:
            // Block Erase (Setup)
            if bank.writable {
                let blockOffset = (offset / bank.blockSize) * bank.blockSize
                bank.state = .eraseSetup(blockOffset: blockOffset)
            } else {
                bank.status |= FlashStatus.eraseError
                bank.state = .readStatus
            }

        case 0x70:
            // Status Register Read
            bank.state = .readStatus

        case 0x50:
            // Clear Status Register
            bank.status = FlashStatus.ready
            bank.state = .readArray

        case 0x90:
            // Read Electronic Signature
            bank.state = .readID

        default:
            // Unknown command -- go to read-status mode with ready flag.
            bank.state = .readStatus
        }
    }

    /// Execute a word program operation on the bank.
    ///
    /// NOR flash programming can only clear bits (1 -> 0). It cannot set bits.
    /// The result is the AND of the existing data and the new value.
    private func executeProgramWord(_ bank: FlashBank, offset: Int, size: Int, value: UInt64) {
        guard bank.writable, offset >= 0, offset + size <= bank.data.count else {
            bank.status |= FlashStatus.programError
            bank.state = .readStatus
            return
        }

        bank.data.withUnsafeMutableBytes { ptr in
            for i in 0..<size {
                let newByte = UInt8(truncatingIfNeeded: value >> (i * 8))
                let existingByte = ptr.load(fromByteOffset: offset + i, as: UInt8.self)
                // NOR flash: can only clear bits (AND operation).
                ptr.storeBytes(of: existingByte & newByte, toByteOffset: offset + i, as: UInt8.self)
            }
        }

        varsDirty = true
        bank.status = FlashStatus.ready
        bank.state = .readStatus
    }

    /// Execute a block erase operation, setting all bytes in the block to 0xFF.
    private func executeBlockErase(_ bank: FlashBank, blockOffset: Int) {
        guard bank.writable,
              blockOffset >= 0,
              blockOffset + bank.blockSize <= bank.data.count else {
            bank.status |= FlashStatus.eraseError
            bank.state = .readStatus
            return
        }

        bank.data.withUnsafeMutableBytes { ptr in
            let dest = ptr.baseAddress!.advanced(by: blockOffset)
            memset(dest, 0xFF, bank.blockSize)
        }

        varsDirty = true
        bank.status = FlashStatus.ready
        bank.state = .readStatus
    }
}
