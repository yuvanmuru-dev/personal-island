/*
 * Personal Island — system activity model and sampling lifecycle.
 * Written for this personal project; no upstream file copied.
 */

import Combine
import Foundation

/// Raw cumulative counters read at one moment. Any value macOS does not
/// provide is nil and is shown as unavailable, never estimated.
struct StatsCounters: Equatable {
    struct CPUTicks: Equatable {
        var busy: UInt64
        var idle: UInt64
    }

    var cpu: CPUTicks?
    /// GPU utilization 0...100 as reported by the graphics driver.
    var gpuPercent: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var networkIn: UInt64?
    var networkOut: UInt64?
    var diskRead: UInt64?
    var diskWritten: UInt64?
    var diskFree: Int64?
    var diskTotal: Int64?
}

/// What the island shows: percentages and per-second rates.
struct StatsReading: Equatable {
    var cpuPercent: Double?
    var gpuPercent: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var networkInPerSecond: Double?
    var networkOutPerSecond: Double?
    var diskReadPerSecond: Double?
    var diskWritePerSecond: Double?
    var diskFree: Int64?
    var diskTotal: Int64?

    var memoryPercent: Double? {
        guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
        return min(100, Double(used) / Double(total) * 100)
    }
}

enum SystemStats {
    /// Seconds between samples while the Stats tab is visible.
    static let interval: TimeInterval = 1
    /// Samples kept for the small graphs.
    static let historyLength = 60

    /// Turns two samples into a reading. Rates need both samples and a
    /// positive interval; a counter that went backwards (an interface or disk
    /// came and went) gives no rate for that step rather than a huge spike.
    static func reading(from old: StatsCounters?, to new: StatsCounters, seconds: TimeInterval) -> StatsReading {
        let valid = old != nil && seconds.isFinite && seconds > 0
        func rate(_ a: UInt64?, _ b: UInt64?) -> Double? {
            guard valid, let a, let b, b >= a else { return nil }
            return Double(b - a) / seconds
        }
        var cpu: Double?
        if let a = old?.cpu, let b = new.cpu, b.busy >= a.busy, b.idle >= a.idle {
            let busy = b.busy - a.busy, total = busy + (b.idle - a.idle)
            cpu = total > 0 ? Double(busy) / Double(total) * 100 : nil
        }
        let gpu = new.gpuPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        var memoryValid = false
        if let used = new.memoryUsed, let total = new.memoryTotal { memoryValid = total > 0 && used <= total }
        return StatsReading(
            cpuPercent: cpu,
            gpuPercent: gpu,
            memoryUsed: memoryValid ? new.memoryUsed : nil,
            memoryTotal: memoryValid ? new.memoryTotal : nil,
            networkInPerSecond: rate(old?.networkIn, new.networkIn),
            networkOutPerSecond: rate(old?.networkOut, new.networkOut),
            diskReadPerSecond: rate(old?.diskRead, new.diskRead),
            diskWritePerSecond: rate(old?.diskWritten, new.diskWritten),
            diskFree: new.diskFree.flatMap { $0 >= 0 ? $0 : nil },
            diskTotal: new.diskTotal.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// "12%", or "—" when unavailable.
    static func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// Bytes as "512 KB", "3.4 MB", "1.2 GB". Decimal units like Finder by
    /// default; memory uses 1024s like Activity Monitor ("16 GB" of RAM).
    static func bytesText(_ value: Double?, binary: Bool = false) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        let base: Double = binary ? 1_024 : 1_000
        var amount = value, index = 0
        while amount >= base, index < units.count - 1 {
            amount /= base
            index += 1
        }
        let digits = index == 0 || amount >= 100 ? 0 : 1
        return String(format: "%.\(digits)f %@", amount, units[index])
    }

    static func rateText(_ value: Double?) -> String {
        guard value != nil else { return "—" }
        return bytesText(value) + "/s"
    }
}

/// Recent values for the small graphs, oldest first.
struct StatsHistory: Equatable {
    var cpu: [Double] = []
    var memory: [Double] = []
    var network: [Double] = []
    var disk: [Double] = []
}

/// Samples only while started; the coordinator starts it while the Stats tab
/// is on screen and stops it when the island closes or the switch is off.
@MainActor
final class StatsController {
    struct Environment {
        var sample: @MainActor () -> StatsCounters
        var now: @MainActor () -> Date
        /// Calls the action every `interval` seconds until cancelled.
        var repeating: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable
    }

    private(set) var reading: StatsReading?
    /// Oldest first, at most `SystemStats.historyLength` each.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var networkHistory: [Double] = []
    private(set) var diskHistory: [Double] = []
    var onChange: (@MainActor () -> Void)?

    private let environment: Environment
    private var timer: AnyCancellable?
    private var last: (counters: StatsCounters, at: Date)?
    private var generation = 0

    var isSampling: Bool { timer != nil }

    init(environment: Environment) {
        self.environment = environment
    }

    func start() {
        guard timer == nil else { return }
        generation += 1
        let session = generation
        sample()
        timer = environment.repeating(SystemStats.interval) { [weak self] in
            guard let self, session == self.generation else { return }
            self.sample()
        }
    }

    /// Stops sampling and forgets every reading and graph.
    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        last = nil
        guard reading != nil || !cpuHistory.isEmpty else { return }
        reading = nil
        cpuHistory = []
        memoryHistory = []
        networkHistory = []
        diskHistory = []
        onChange?()
    }

    private func sample() {
        let now = environment.now()
        let counters = environment.sample()
        let next = SystemStats.reading(from: last?.counters, to: counters,
                                       seconds: last.map { now.timeIntervalSince($0.at) } ?? 0)
        last = (counters, now)
        reading = next
        if let cpu = next.cpuPercent { append(cpu, to: &cpuHistory) }
        if let memory = next.memoryPercent { append(memory, to: &memoryHistory) }
        if let down = next.networkInPerSecond, let up = next.networkOutPerSecond { append(down + up, to: &networkHistory) }
        if let read = next.diskReadPerSecond, let write = next.diskWritePerSecond { append(read + write, to: &diskHistory) }
        onChange?()
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > SystemStats.historyLength { history.removeFirst(history.count - SystemStats.historyLength) }
    }
}
