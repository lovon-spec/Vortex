// FWCfg.swift -- QEMU fw_cfg compatible MMIO device.
// VortexHV
//
// The fw_cfg device provides a simple interface for passing firmware
// configuration data between the VMM and guest firmware/kernel.
// It uses a selector/data register pair accessible via MMIO.
//
// Register layout (MMIO, big-endian):
//   Offset 0x00: Data register (8 bytes, read/write)
//   Offset 0x08: Selector register (2 bytes, write-only)
//   Offset 0x10: DMA address register (8 bytes, write-only)
//
// Well-known selector keys:
//   0x0000: Signature ("QEMU")
//   0x0001: Interface ID
//   0x0005: Number of file entries
//   0x0019: File directory

import Foundation

// MARK: - FW Cfg Keys

/// Well-known fw_cfg selector keys.
public enum FWCfgKey: UInt16 {
    case signature      = 0x0000
    case id             = 0x0001
    case fileDir        = 0x0019
    case kernelAddr     = 0x0007
    case kernelSize     = 0x0008
    case kernelCmdline  = 0x0009
    case initrdAddr     = 0x000A
    case initrdSize     = 0x000B
    case kernelEntry    = 0x0010
    case kernelData     = 0x0011
    case initrdData     = 0x0012
    case cmdlineAddr    = 0x0013
    case cmdlineSize    = 0x0014
    case cmdlineData    = 0x0015
}

// MARK: - FW Cfg File Entry

/// A named file in the fw_cfg file directory.
public struct FWCfgFile {
    /// File size in bytes.
    public let size: UInt32
    /// Selector key.
    public let select: UInt16
    /// Reserved field.
    public let reserved: UInt16
    /// File name (NUL-padded to 56 bytes).
    public let name: String
    /// File data.
    public let data: Data

    public init(name: String, select: UInt16, data: Data) {
        self.name = name
        self.select = select
        self.size = UInt32(data.count)
        self.reserved = 0
        self.data = data
    }
}

// MARK: - FW Cfg Device

/// MMIO fw_cfg device for passing configuration data to guest firmware.
public final class FWCfgDevice: MMIODevice, @unchecked Sendable {
    public let baseAddress: UInt64
    public let regionSize: UInt64 = 0x1000

    // Registers
    private let lock = NSLock()
    private var selector: UInt16 = 0
    private var dataOffset: Int = 0

    // Static well-known data
    private let signatureData = Data("QEMU".utf8)
    private let idData: Data = {
        // Interface ID: bit 1 = DMA supported (we do not support DMA yet)
        var data = Data(count: 4)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(0x0000_0001).bigEndian, as: UInt32.self) // Traditional interface
        }
        return data
    }()

    // Custom file entries (selector -> data)
    private var entries: [UInt16: Data] = [:]
    private var files: [FWCfgFile] = []
    private var nextFileSelector: UInt16 = 0x0020 // First user file selector

    public init(baseAddress: UInt64 = MachineMemoryMap.fwCfgBase) {
        self.baseAddress = baseAddress
    }

    /// Add a named file to the fw_cfg device.
    /// - Returns: The selector key for this file.
    @discardableResult
    public func addFile(name: String, data: Data) -> UInt16 {
        lock.lock()
        let selector = nextFileSelector
        nextFileSelector += 1
        let file = FWCfgFile(name: name, select: selector, data: data)
        files.append(file)
        entries[selector] = data
        lock.unlock()
        return selector
    }

    /// Add raw data for a well-known selector key.
    public func addEntry(key: UInt16, data: Data) {
        lock.lock()
        entries[key] = data
        lock.unlock()
    }

    /// Add a string for a well-known selector key.
    public func addEntry(key: UInt16, string: String) {
        var data = Data(string.utf8)
        data.append(0) // NUL terminator
        addEntry(key: key, data: data)
    }

    // MARK: - MMIO Interface

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case 0x00: // Data register
            return readDataRegister(size: size)
        case 0x08: // Selector register (read returns current selector)
            return UInt64(selector)
        default:
            return 0
        }
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case 0x08: // Selector register
            selector = UInt16(truncatingIfNeeded: value)
            dataOffset = 0
        case 0x00: // Data register (write -- used for DMA commands, not typical)
            break
        default:
            break
        }
    }

    // MARK: - Private

    private func readDataRegister(size: Int) -> UInt64 {
        guard let data = dataForCurrentSelector() else {
            return 0
        }

        var result: UInt64 = 0
        let available = data.count - dataOffset
        let bytesToRead = min(size, available)

        if bytesToRead > 0 {
            data.withUnsafeBytes { ptr in
                for i in 0..<bytesToRead {
                    let byte = ptr.load(fromByteOffset: dataOffset + i, as: UInt8.self)
                    result |= UInt64(byte) << (i * 8)
                }
            }
            dataOffset += bytesToRead
        }

        return result
    }

    private func dataForCurrentSelector() -> Data? {
        switch selector {
        case FWCfgKey.signature.rawValue:
            return signatureData
        case FWCfgKey.id.rawValue:
            return idData
        case FWCfgKey.fileDir.rawValue:
            return buildFileDirectory()
        default:
            return entries[selector]
        }
    }

    private func buildFileDirectory() -> Data {
        // File directory format:
        // 4 bytes: number of files (big-endian)
        // For each file:
        //   4 bytes: size (big-endian)
        //   2 bytes: select key (big-endian)
        //   2 bytes: reserved
        //   56 bytes: name (NUL-padded)
        let entrySize = 4 + 2 + 2 + 56
        var data = Data(count: 4 + files.count * entrySize)

        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(files.count).bigEndian, toByteOffset: 0, as: UInt32.self)

            for (i, file) in files.enumerated() {
                let offset = 4 + i * entrySize
                ptr.storeBytes(of: file.size.bigEndian, toByteOffset: offset, as: UInt32.self)
                ptr.storeBytes(of: file.select.bigEndian, toByteOffset: offset + 4, as: UInt16.self)
                ptr.storeBytes(of: file.reserved.bigEndian, toByteOffset: offset + 6, as: UInt16.self)

                // Copy name (up to 55 chars + NUL).
                let nameBytes = Array(file.name.utf8.prefix(55))
                for (j, byte) in nameBytes.enumerated() {
                    ptr.storeBytes(of: byte, toByteOffset: offset + 8 + j, as: UInt8.self)
                }
                // Rest is already zeroed.
            }
        }

        return data
    }
}
