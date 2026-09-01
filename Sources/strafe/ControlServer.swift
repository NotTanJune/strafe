import Darwin
import Foundation

/// Local control endpoint shared with OpenLogi.
///
/// The socket is intentionally local, owner-only, and accepts one fixed
/// command shape. It lets another input front end reuse Strafe's live,
/// in-memory transition-speed selection without duplicating the switch engine.
enum StrafeControl {
    static let socketPath = "/tmp/strafe.sock"
}

/// Serves single-step Space-switch requests for other local input tools.
///
/// The server never exposes a network listener. Each request is handled on a
/// serial queue so rapid OpenLogi gestures reach the same engine in order.
final class StrafeControlServer: @unchecked Sendable {
    private let engine: GestureSwitchEngine
    private let queue = DispatchQueue(
        label: "com.rileycx.strafe.control",
        qos: .userInitiated
    )
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(engine: GestureSwitchEngine) {
        self.engine = engine
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil

            if listenFD >= 0 {
                Darwin.close(listenFD)
                listenFD = -1
            }

            removeOwnedSocket()
        }
    }

    private func startOnQueue() {
        guard listenFD < 0 else { return }
        guard removeOwnedSocket() else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("socket creation failed: errno \(errno)")
            return
        }

        guard var address = makeAddress() else {
            Darwin.close(fd)
            return
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    fd,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            log("bind failed: errno \(errno)")
            Darwin.close(fd)
            return
        }

        guard chmod(StrafeControl.socketPath, mode_t(0o600)) == 0 else {
            log("socket permission setup failed: errno \(errno)")
            Darwin.close(fd)
            removeOwnedSocket()
            return
        }

        guard listen(fd, 8) == 0 else {
            log("listen failed: errno \(errno)")
            Darwin.close(fd)
            removeOwnedSocket()
            return
        }

        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            log("nonblocking setup failed: errno \(errno)")
            Darwin.close(fd)
            removeOwnedSocket()
            return
        }

        listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.acceptClients()
        }
        readSource.setCancelHandler {}
        source = readSource
        readSource.resume()
    }

    private func acceptClients() {
        guard listenFD >= 0 else { return }

        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD >= 0 {
                handle(clientFD)
                continue
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            log("accept failed: errno \(errno)")
            return
        }
    }

    private func handle(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 128)

        while request.count < buffer.count {
            var descriptor = pollfd(
                fd: clientFD,
                events: Int16(POLLIN),
                revents: 0
            )
            guard Darwin.poll(&descriptor, 1, 100) > 0 else {
                writeResponse("error timeout\n", to: clientFD)
                return
            }

            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(clientFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count > 0 else {
                writeResponse("error empty request\n", to: clientFD)
                return
            }

            request.append(contentsOf: buffer.prefix(count))
            if buffer.prefix(count).contains(0x0A) {
                break
            }
        }

        guard let command = String(data: request, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            writeResponse("error invalid encoding\n", to: clientFD)
            return
        }

        let direction: SwitchDirection
        switch command {
        case "switch left":
            direction = .left
        case "switch right":
            direction = .right
        default:
            writeResponse("error unknown command\n", to: clientFD)
            return
        }

        do {
            try engine.switchSpace(direction)
            writeResponse("ok\n", to: clientFD)
        } catch {
            writeResponse("error switch failed\n", to: clientFD)
        }
    }

    private func writeResponse(_ response: String, to clientFD: Int32) {
        var bytes = Array(response.utf8)
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { rawBytes in
                Darwin.write(clientFD, rawBytes.baseAddress, rawBytes.count)
            }
            guard written > 0 else { return }
            bytes.removeFirst(written)
        }
    }

    private func makeAddress() -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(StrafeControl.socketPath.utf8) + [0]
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            log("socket path is too long")
            return nil
        }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return address
    }

    @discardableResult
    private func removeOwnedSocket() -> Bool {
        var fileInfo = Darwin.stat()
        let status = StrafeControl.socketPath.withCString { path in
            Darwin.lstat(path, &fileInfo)
        }

        if status != 0 {
            return errno == ENOENT
        }

        let fileType = fileInfo.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFSOCK), fileInfo.st_uid == getuid() else {
            log("refusing to replace an unexpected socket path")
            return false
        }

        return StrafeControl.socketPath.withCString { path in
            Darwin.unlink(path) == 0
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[ControlServer] \(message)\n".utf8))
    }
}
