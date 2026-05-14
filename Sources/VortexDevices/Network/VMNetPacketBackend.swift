// VMNetPacketBackend.swift -- vmnet-backed packet backend for virtio-net.
// VortexDevices

import Darwin
import Dispatch
import Foundation
import vmnet
import XPC
import VortexCore

public final class VMNetPacketBackend: NetworkPacketBackend, @unchecked Sendable {
    public let mode: NetworkMode
    public let macAddress: String
    public let mtu: UInt16

    private let queue = DispatchQueue(label: "vortex.vmnet.packet-backend")
    private let lock = NSLock()
    private var interface: interface_ref?
    private var onPacket: (@Sendable (Data) -> Void)?
    private var stopped = false

    public init(mode: NetworkMode, macAddress: String, mtu: UInt16 = 1500) {
        self.mode = mode
        self.macAddress = macAddress
        self.mtu = mtu
    }

    public func start(onPacket: @escaping @Sendable (Data) -> Void) throws {
        lock.lock()
        if interface != nil {
            self.onPacket = onPacket
            lock.unlock()
            return
        }
        self.onPacket = onPacket
        stopped = false
        lock.unlock()

        let descriptor = try makeInterfaceDescriptor()
        let semaphore = DispatchSemaphore(value: 0)
        var startStatus = vmnet_return_t.VMNET_FAILURE
        var startParameters: xpc_object_t?

        guard let newInterface = vmnet_start_interface(descriptor, queue, { status, parameters in
            startStatus = status
            startParameters = parameters
            semaphore.signal()
        }) else {
            throw NetworkPacketBackendError.startFailed("vmnet_start_interface returned nil.")
        }

        semaphore.wait()
        guard startStatus == vmnet_return_t.VMNET_SUCCESS else {
            stopInterface(newInterface)
            throw NetworkPacketBackendError.startFailed(statusDescription(startStatus))
        }

        if let startParameters,
           let mac = xpc_dictionary_get_string(startParameters, vmnet_mac_address_key) {
            VortexLog.service.info("vmnet interface started with MAC \(String(cString: mac))")
        }

        lock.lock()
        interface = newInterface
        lock.unlock()

        let callbackStatus = vmnet_interface_set_event_callback(
            newInterface,
            interface_event_t.VMNET_INTERFACE_PACKETS_AVAILABLE,
            queue
        ) { [weak self] _, _ in
            self?.readAvailablePackets()
        }
        guard callbackStatus == vmnet_return_t.VMNET_SUCCESS else {
            stop()
            throw NetworkPacketBackendError.startFailed(statusDescription(callbackStatus))
        }
    }

    public func send(packet: Data) throws {
        guard !packet.isEmpty else { return }

        lock.lock()
        let currentInterface = interface
        lock.unlock()
        guard let currentInterface else {
            throw NetworkPacketBackendError.sendFailed("vmnet interface is not started.")
        }

        var mutablePacket = packet
        let status: vmnet_return_t = mutablePacket.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                return vmnet_return_t.VMNET_INVALID_ARGUMENT
            }
            var iov = iovec(iov_base: base, iov_len: packet.count)
            return withUnsafeMutablePointer(to: &iov) { iovPointer in
                var descriptor = vmpktdesc(
                    vm_pkt_size: packet.count,
                    vm_pkt_iov: iovPointer,
                    vm_pkt_iovcnt: 1,
                    vm_flags: 0
                )
                var packetCount: Int32 = 1
                return vmnet_write(currentInterface, &descriptor, &packetCount)
            }
        }

        guard status == vmnet_return_t.VMNET_SUCCESS else {
            throw NetworkPacketBackendError.sendFailed(statusDescription(status))
        }
    }

    public func stop() {
        lock.lock()
        let currentInterface = interface
        interface = nil
        onPacket = nil
        stopped = true
        lock.unlock()

        if let currentInterface {
            stopInterface(currentInterface)
        }
    }

    deinit {
        stop()
    }

    private func makeInterfaceDescriptor() throws -> xpc_object_t {
        let descriptor = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(descriptor, vmnet_operation_mode_key, UInt64(vmnetMode().rawValue))
        xpc_dictionary_set_string(descriptor, vmnet_mac_address_key, macAddress)
        xpc_dictionary_set_bool(descriptor, vmnet_allocate_mac_address_key, false)
        xpc_dictionary_set_uint64(descriptor, vmnet_mtu_key, UInt64(mtu))

        switch mode {
        case .bridged(let hostInterface):
            xpc_dictionary_set_string(descriptor, vmnet_shared_interface_name_key, hostInterface)
        case .vmnetShared(let vmnet):
            if let subnet = vmnet.ipv4Subnet {
                xpc_dictionary_set_string(descriptor, vmnet_start_address_key, subnet.hostAddress)
                xpc_dictionary_set_string(descriptor, vmnet_end_address_key, subnet.hostAddress)
                xpc_dictionary_set_string(descriptor, vmnet_subnet_mask_key, subnet.subnetMask)
            }
        case .nat, .hostOnly:
            break
        }

        return descriptor
    }

    private func vmnetMode() -> operating_modes_t {
        switch mode {
        case .nat, .vmnetShared:
            return operating_modes_t.VMNET_SHARED_MODE
        case .bridged:
            return operating_modes_t.VMNET_BRIDGED_MODE
        case .hostOnly:
            return operating_modes_t.VMNET_HOST_MODE
        }
    }

    private func readAvailablePackets() {
        lock.lock()
        let currentInterface = interface
        let packetHandler = onPacket
        let shouldStop = stopped
        lock.unlock()
        guard let currentInterface, let packetHandler, !shouldStop else { return }

        for _ in 0..<64 {
            var packetSize = 0
            var packetData = Data(count: 2048)
            let status: vmnet_return_t = packetData.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else {
                    return vmnet_return_t.VMNET_INVALID_ARGUMENT
                }
                var iov = iovec(iov_base: base, iov_len: bytes.count)
                return withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var descriptor = vmpktdesc(
                        vm_pkt_size: bytes.count,
                        vm_pkt_iov: iovPointer,
                        vm_pkt_iovcnt: 1,
                        vm_flags: 0
                    )
                    var packetCount: Int32 = 1
                    let readStatus = vmnet_read(currentInterface, &descriptor, &packetCount)
                    if readStatus == vmnet_return_t.VMNET_SUCCESS, packetCount > 0 {
                        packetSize = descriptor.vm_pkt_size
                    }
                    return readStatus
                }
            }

            guard status == vmnet_return_t.VMNET_SUCCESS, packetSize > 0 else {
                return
            }
            packetData.removeSubrange(packetSize..<packetData.count)
            packetHandler(packetData)
        }
    }

    private func stopInterface(_ interface: interface_ref) {
        _ = vmnet_interface_set_event_callback(interface, [], nil, nil)

        let semaphore = DispatchSemaphore(value: 0)
        let status = vmnet_stop_interface(interface, DispatchQueue.global()) { _ in
            semaphore.signal()
        }
        if status == vmnet_return_t.VMNET_SUCCESS {
            _ = semaphore.wait(timeout: .now() + .seconds(2))
        }
    }

    private func statusDescription(_ status: vmnet_return_t) -> String {
        switch status {
        case vmnet_return_t.VMNET_SUCCESS:
            return "success"
        case vmnet_return_t.VMNET_FAILURE:
            return "general failure"
        case vmnet_return_t.VMNET_INVALID_ACCESS:
            return "invalid access"
        case vmnet_return_t.VMNET_NOT_AUTHORIZED:
            return "not authorized"
        case vmnet_return_t.VMNET_SHARING_SERVICE_BUSY:
            return "sharing service busy"
        default:
            return "vmnet status \(status.rawValue)"
        }
    }
}
