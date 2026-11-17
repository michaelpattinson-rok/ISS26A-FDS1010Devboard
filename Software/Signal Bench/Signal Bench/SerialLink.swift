import Foundation
import Darwin

protocol SerialTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onDisconnect: ((String) -> Void)? { get set }
    func openPort(_ path: String) throws
    func closePort()
    func send(_ message: String) throws
}

final class SerialLink: SerialTransport {
    private let queue = DispatchQueue(label: "SignalBench.USB")
    private let queueKey = DispatchSpecificKey<Bool>()
    init() { queue.setSpecific(key: queueKey, value: true) }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var decoder = BinaryTransferDecoder()
    private var generation = UUID()
    private var deliveryPending = false
    var onLine: ((String) -> Void)?
    var onDisconnect: ((String) -> Void)?

    static func ports() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }
    func openPort(_ path: String) throws {
        guard Self.ports().contains(path) else { throw SBProtocolError.invalid("Select an available USB serial port.") }
        closePort()
        try queue.sync {
            let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard handle >= 0 else { throw SBProtocolError.invalid("Could not open the USB port. Check access and close other serial monitors.") }
            var options = termios()
            guard tcgetattr(handle, &options) == 0 else { Darwin.close(handle); throw SBProtocolError.invalid("Could not configure the USB port.") }
            cfmakeraw(&options); options.c_cflag |= UInt(CLOCAL | CREAD)
            cfsetspeed(&options, speed_t(B115200))
            guard tcsetattr(handle, TCSANOW, &options) == 0 else { Darwin.close(handle); throw SBProtocolError.invalid("Could not configure the USB port.") }
            fd = handle
            let reader = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            reader.resume(); source = reader
        }
    }
    func closePort() {
        let close = { [self] in
            generation = UUID()
            if deliveryPending { source?.resume(); deliveryPending = false }
            source?.cancel(); source = nil
            if fd >= 0 { Darwin.close(fd); fd = -1 }
            decoder = BinaryTransferDecoder()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { close() } else { queue.sync(execute: close) }
    }
    deinit { closePort() }
    func send(_ message: String) throws {
        try queue.sync {
            guard fd >= 0 else { throw SBProtocolError.invalid("The device is disconnected.") }
            if message.hasPrefix("SB1 GETB ") { decoder.allowBinary = true }
            let bytes = Array(message.utf8)
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw SBProtocolError.invalid("USB command write failed. Reconnect and check the pending record.")
            }
        }
    }
    private func readAvailable() {
        guard fd >= 0, !deliveryPending else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        let identity = generation
        do {
            guard n > 0 else { throw SBProtocolError.invalid("USB connection ended.") }
            let lines = try decoder.append(Data(bytes.prefix(n)))
            guard !lines.isEmpty else { return }
            // At most one 4 KiB read awaits the UI. Backpressure stays in USB.
            deliveryPending = true; source?.suspend()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let current = self.queue.sync { self.generation == identity }
                if current { for line in lines { self.onLine?(line) } }
                self.queue.async {
                    if self.generation == identity && self.deliveryPending {
                        self.deliveryPending = false; self.source?.resume()
                    }
                }
            }
        } catch {
            source?.cancel(); source = nil
            Darwin.close(fd); fd = -1
            DispatchQueue.main.async { [weak self] in
                guard let self, self.queue.sync(execute: { self.generation == identity }) else { return }
                self.onDisconnect?(error.localizedDescription)
            }
        }
    }
}
