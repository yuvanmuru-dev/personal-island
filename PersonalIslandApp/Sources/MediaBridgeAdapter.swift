/*
 * Personal Island — media bridge process adapter.
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import Combine

/// Real platform access for `MediaSessionsController`: runs the bundled
/// MediaBridge.dylib under Apple's /usr/bin/perl (the app itself cannot read
/// other apps' Now Playing sessions). Absolute paths only, a minimal
/// environment, and the helper exits when its input is closed.
@MainActor
enum MediaBridgeAdapter {
    static func environment() -> MediaSessionsController.Environment {
        MediaSessionsController.Environment(
            launch: { onLine, onExit in launch(onLine: onLine, onExit: onExit) },
            send: { helper, line in (helper as? Helper)?.send(line) },
            terminate: { ($0 as? Helper)?.terminate() },
            now: { Date() },
            schedule: { delay, action in
                let timer = Timer(timeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated { action() }
                }
                RunLoop.main.add(timer, forMode: .common)
                return AnyCancellable { timer.invalidate() }
            }
        )
    }

    private static func launch(onLine: @escaping @MainActor (String) -> Void,
                               onExit: @escaping @MainActor () -> Void) -> AnyObject? {
        guard let loader = Bundle.main.url(forResource: "MediaBridge", withExtension: "pl"),
              let library = Bundle.main.url(forResource: "MediaBridge", withExtension: "dylib") else { return nil }
        let helper = Helper(onLine: onLine, onExit: onExit)
        return helper.start(loader: loader, library: library) ? helper : nil
    }

    /// One running helper process.
    @MainActor
    final class Helper {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var buffer = Data()
        private let onLine: @MainActor (String) -> Void
        private let onExit: @MainActor () -> Void

        init(onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor () -> Void) {
            self.onLine = onLine
            self.onExit = onExit
        }

        func start(loader: URL, library: URL) -> Bool {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [loader.path, library.path]
            process.environment = ["PERSONAL_ISLAND_MEDIA_BRIDGE": "1"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
            }
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended() } }
            }
            do {
                try process.run()
                return true
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                return false
            }
        }

        func send(_ line: String) {
            guard process.isRunning, let data = line.data(using: .utf8) else { return }
            try? input.fileHandleForWriting.write(contentsOf: data)
        }

        /// Closing its input makes the helper exit; terminate if it lingers.
        func terminate() {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            try? input.fileHandleForWriting.close()
            let process = self.process
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if process.isRunning { process.terminate() }
            }
        }

        private func received(_ data: Data) {
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let text = String(data: line, encoding: .utf8) { onLine(text) }
            }
            // A runaway line is dropped rather than buffered without limit.
            if buffer.count > MediaSessions.maximumLineLength { buffer.removeAll() }
        }

        private func ended() {
            output.fileHandleForReading.readabilityHandler = nil
            onExit()
        }
    }
}
