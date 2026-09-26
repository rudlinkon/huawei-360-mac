import CLibUSB
import Foundation

public enum CV60Error: Error, CustomStringConvertible {
    case libusb(String, Int32)
    case notFound
    case noBulkInterface
    case badCSW(String)
    case camera(String)

    public var description: String {
        switch self {
        case let .libusb(op, code):
            let name = String(cString: libusb_error_name(code))
            var hint = ""
            if code == LIBUSB_ERROR_ACCESS.rawValue || code == LIBUSB_ERROR_BUSY.rawValue {
                hint = "\n  -> macOS mass-storage driver probably owns the camera. Run with sudo so the driver can be detached."
            }
            return "\(op) failed: \(name) (\(code))\(hint)"
        case .notFound:
            return "Huawei CV60 camera (12d1:109b) not found. Plug it in and power it on."
        case .noBulkInterface:
            return "No interface with bulk IN + OUT endpoints found."
        case let .badCSW(msg):
            return "Bad SCSI status: \(msg)"
        case let .camera(msg):
            return msg
        }
    }
}

public struct USBEndpointInfo: CustomStringConvertible {
    public let address: UInt8
    public let attributes: UInt8
    public let maxPacketSize: UInt16
    public var description: String {
        let dir = address & 0x80 != 0 ? "IN " : "OUT"
        let types = ["control", "iso", "bulk", "interrupt"]
        return String(format: "ep 0x%02x %@ %@ maxPacket=%d", address, dir, types[Int(attributes & 3)], maxPacketSize)
    }
}

public struct USBInterfaceInfo: CustomStringConvertible {
    public let number: UInt8
    public let klass: UInt8
    public let subclass: UInt8
    public let proto: UInt8
    public let endpoints: [USBEndpointInfo]
    public var description: String {
        var s = String(format: "interface %d class=0x%02x subclass=0x%02x protocol=0x%02x", number, klass, subclass, proto)
        for ep in endpoints { s += "\n    \(ep)" }
        return s
    }
}

/// Thin wrapper around libusb for the CV60 (VID 0x12D1, PID 0x109B — from res/xml/usb_device_filter.xml).
public final class USBDevice {
    public static let vendorID: UInt16 = 0x12D1
    public static let productID: UInt16 = 0x109B

    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?
    private(set) public var interfaceNumber: Int32 = -1
    private(set) public var epIn: UInt8 = 0
    private(set) public var epOut: UInt8 = 0
    private(set) public var interfaces: [USBInterfaceInfo] = []
    public var log: (String) -> Void = { _ in }

    public init() throws {
        try check(libusb_init(&ctx), "libusb_init")
    }

    deinit {
        close()
        if let ctx { libusb_exit(ctx) }
    }

    private func check(_ rc: Int32, _ op: String) throws {
        if rc < 0 { throw CV60Error.libusb(op, rc) }
    }

    public func open() throws {
        guard let h = libusb_open_device_with_vid_pid(ctx, Self.vendorID, Self.productID) else {
            throw CV60Error.notFound
        }
        handle = h
        interfaces = try readInterfaces()
        for i in interfaces { log("\(i)") }

        // Same rule as the Android app: first interface that has one bulk IN and one bulk OUT.
        guard let iface = interfaces.first(where: { i in
            i.endpoints.contains { $0.attributes & 3 == 2 && $0.address & 0x80 != 0 } &&
                i.endpoints.contains { $0.attributes & 3 == 2 && $0.address & 0x80 == 0 }
        }) else { throw CV60Error.noBulkInterface }
        interfaceNumber = Int32(iface.number)
        epIn = iface.endpoints.first { $0.attributes & 3 == 2 && $0.address & 0x80 != 0 }!.address
        epOut = iface.endpoints.first { $0.attributes & 3 == 2 && $0.address & 0x80 == 0 }!.address

        // macOS attaches its mass-storage driver to this interface. libusb can detach it (needs root).
        _ = libusb_set_auto_detach_kernel_driver(h, 1)
        if libusb_kernel_driver_active(h, interfaceNumber) == 1 {
            log("kernel driver active on interface \(interfaceNumber), detaching")
            let rc = libusb_detach_kernel_driver(h, interfaceNumber)
            if rc < 0 { log("detach failed: \(String(cString: libusb_error_name(rc)))") }
        }
        try check(libusb_claim_interface(h, interfaceNumber), "claim_interface")
        log(String(format: "claimed interface %d, bulk in 0x%02x out 0x%02x", interfaceNumber, epIn, epOut))
    }

    public func close() {
        guard let h = handle else { return }
        if interfaceNumber >= 0 { libusb_release_interface(h, interfaceNumber) }
        libusb_close(h)
        handle = nil
    }

    private func readInterfaces() throws -> [USBInterfaceInfo] {
        guard let dev = libusb_get_device(handle) else { return [] }
        var cfgPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        try check(libusb_get_active_config_descriptor(dev, &cfgPtr), "get_config_descriptor")
        guard let cfg = cfgPtr else { return [] }
        defer { libusb_free_config_descriptor(cfg) }
        var result: [USBInterfaceInfo] = []
        for i in 0..<Int(cfg.pointee.bNumInterfaces) {
            let iface = cfg.pointee.interface[i]
            guard iface.num_altsetting > 0 else { continue }
            let alt = iface.altsetting[0]
            var eps: [USBEndpointInfo] = []
            for e in 0..<Int(alt.bNumEndpoints) {
                let ep = alt.endpoint[e]
                eps.append(USBEndpointInfo(address: ep.bEndpointAddress, attributes: ep.bmAttributes, maxPacketSize: ep.wMaxPacketSize))
            }
            result.append(USBInterfaceInfo(number: alt.bInterfaceNumber, klass: alt.bInterfaceClass,
                                           subclass: alt.bInterfaceSubClass, proto: alt.bInterfaceProtocol, endpoints: eps))
        }
        return result
    }

    /// Returns bytes transferred. Timeouts that moved some data are returned as partial success.
    public func bulk(_ endpoint: UInt8, _ buffer: UnsafeMutablePointer<UInt8>, _ length: Int, timeoutMs: UInt32) throws -> Int {
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(handle, endpoint, buffer, Int32(length), &transferred, timeoutMs)
        if rc == LIBUSB_ERROR_PIPE.rawValue {
            libusb_clear_halt(handle, endpoint)
        }
        if rc < 0 && !(rc == LIBUSB_ERROR_TIMEOUT.rawValue && transferred > 0) {
            throw CV60Error.libusb("bulk transfer ep 0x\(String(endpoint, radix: 16))", rc)
        }
        return Int(transferred)
    }

    /// Bulk-Only Mass Storage Reset (class request 0xFF), exactly as the Android app sends it.
    public func massStorageReset() throws {
        let rc = libusb_control_transfer(handle, 0x21, 0xFF, 0, UInt16(interfaceNumber), nil, 0, 2000)
        try check(rc, "mass storage reset")
    }

    public func clearHalts() {
        libusb_clear_halt(handle, epIn)
        libusb_clear_halt(handle, epOut)
    }
}
