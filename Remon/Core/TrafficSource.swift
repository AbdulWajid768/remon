import Darwin
import Foundation

/// Produces per-process / per-socket byte counters.
///
/// The shipping implementation shells out to `/usr/bin/nettop`, which reads the kernel's
/// `com.apple.network.statistics` control socket and sees every process without root.
/// A Network Extension–based source could replace it behind this protocol.
protocol TrafficSource: Sendable {
    func frames(interval: Int, includeLoopback: Bool) -> AsyncThrowingStream<NettopFrame, Error>
}

enum TrafficSourceError: LocalizedError {
    case exited(Int32)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .exited(let code): "nettop exited unexpectedly (status \(code))."
        case .unavailable(let why): why
        }
    }
}

final class NettopTrafficSource: TrafficSource {
    static let executable = URL(fileURLWithPath: "/usr/bin/nettop")

    /// Kills `nettop` streams orphaned by a previous Remon that crashed or was force-killed
    /// (a pty child that isn't a session leader gets no SIGHUP when its parent dies).
    static func reapOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), parts[1] == "1" else { continue }
            // nettop rewrites its argv, so match on the stable prefix of our invocation.
            if parts[2].hasPrefix("/usr/bin/nettop -L 0 -s ") && parts[2].contains(" -x -n -J interface") {
                kill(pid, SIGTERM)
            }
        }
    }

    func frames(interval: Int, includeLoopback: Bool) -> AsyncThrowingStream<NettopFrame, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: Self.executable.path) else {
                continuation.finish(throwing: TrafficSourceError.unavailable("/usr/bin/nettop is not available on this system."))
                return
            }
            let process = Process()
            process.executableURL = Self.executable
            var arguments = ["-L", "0", "-s", String(max(1, interval)), "-x", "-n",
                             "-J", "interface,state,bytes_in,bytes_out,rtt_avg"]
            if !includeLoopback { arguments += ["-t", "external"] }
            process.arguments = arguments
            // nettop fully buffers its output when writing to a pipe (samples arrive in
            // multi-second bursts), so give it a pseudo-terminal to make it line-buffered.
            guard let pty = PseudoTerminal() else {
                continuation.finish(throwing: TrafficSourceError.unavailable("Couldn't allocate a pseudo-terminal for nettop."))
                return
            }
            process.standardOutput = pty.child
            // stdin must be the pty too: nettop polls stdin for keystrokes and busy-loops
            // (~140% CPU) on the instant EOF of /dev/null.
            process.standardInput = pty.child
            process.standardError = FileHandle.nullDevice
            let handle = pty.parent
            let box = ProcessBox(process)

            let reader = Task.detached(priority: .utility) {
                var parser = NettopParser()
                do {
                    for try await line in handle.bytes.lines {
                        try Task.checkCancellation()
                        if let frame = parser.consume(line) { continuation.yield(frame) }
                    }
                } catch {
                    // A pty read fails with EIO once the child exits; treat it like EOF.
                    if error is CancellationError { continuation.finish(); return }
                }
                if let frame = parser.flush() { continuation.yield(frame) }
                let status = box.waitForExit()
                continuation.finish(throwing: Task.isCancelled ? nil : TrafficSourceError.exited(status))
            }
            continuation.onTermination = { _ in
                reader.cancel()
                box.terminate()
            }
            do {
                try process.run()
                // Close our copy of the child side so reads end when nettop exits.
                try? pty.child.close()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// `Process` isn't `Sendable`; all access after launch goes through this lock-protected box.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.withLock { if process.isRunning { process.terminate() } }
    }

    func waitForExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// A pty pair with output post-processing and echo disabled.
private struct PseudoTerminal {
    let parent: FileHandle
    let child: FileHandle

    init?() {
        var parentFD: Int32 = -1
        var childFD: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&parentFD, &childFD, nil, nil, &size) == 0 else { return nil }
        var attributes = termios()
        if tcgetattr(childFD, &attributes) == 0 {
            attributes.c_oflag &= ~tcflag_t(OPOST)
            attributes.c_lflag &= ~tcflag_t(ECHO | ICANON)
            tcsetattr(childFD, TCSANOW, &attributes)
        }
        parent = FileHandle(fileDescriptor: parentFD, closeOnDealloc: true)
        child = FileHandle(fileDescriptor: childFD, closeOnDealloc: true)
    }
}
