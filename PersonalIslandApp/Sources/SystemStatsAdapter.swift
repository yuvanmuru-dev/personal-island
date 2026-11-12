/*
 * Personal Island — system activity sampling (read-only).
 * Written for this personal project; no upstream file copied.
 */

import Combine
import Darwin
import Foundation
import IOKit

/// Real counters for `StatsController`, from public interfaces only: Mach
/// host statistics (CPU, memory), the routing table's 64-bit interface
/// counters (network), IOKit storage-driver and accelerator statistics (disk,
/// GPU) and the startup volume's capacity. No permission, no process list,
/// nothing about other apps, nothing stored or sent.
@MainActor
enum SystemStatsAdapter {
    static func environment() -> StatsController.Environment {
        StatsController.Environment(
            sample: { sample() },
            now: { Date() },
            repeating: { interval, action in
                let timer = Timer(timeInterval: interval, repeats: true) { _ in
                    MainActor.assumeIsolated { action() }
                }
                timer.tolerance = interval / 5
                RunLoop.main.add(timer, forMode: .common)
                return AnyCancellable { timer.invalidate() }
            }
        )
    }

    private static let host = mach_host_self()
    private static var volume: (free: Int64?, total: Int64?, at: Date)?

    static func sample() -> StatsCounters {
        let memory = memoryUsage()
        let network = networkBytes()
        let disk = diskBytes()
        let space = volumeSpace()
        return StatsCounters(
            cpu: cpuTicks(),
            gpuPercent: gpuUtilization(),
            memoryUsed: memory?.used,
            memoryTotal: memory?.total,
            networkIn: network?.received,
            networkOut: network?.sent,
            diskRead: disk?.read,
            diskWritten: disk?.written,
            diskFree: space.free,
            diskTotal: space.total
        )
    }

    private static func cpuTicks() -> StatsCounters.CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return StatsCounters.CPUTicks(
            busy: UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3),
            idle: UInt64(ticks.2)
        )
    }

    /// "Memory used" as Activity Monitor counts it: app memory (anonymous,
    /// non-purgeable pages), wired and compressed.
    private static func memoryUsage() -> (used: UInt64, total: UInt64)? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let app = UInt64(info.internal_page_count) &- min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
        let used = (app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    /// Bytes received and sent on all non-loopback interfaces.
    private static func networkBytes() -> (received: UInt64, sent: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        var received: UInt64 = 0, sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length,
                   header.ifm_flags & IFF_LOOPBACK == 0 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    received &+= message.ifm_data.ifi_ibytes
                    sent &+= message.ifm_data.ifi_obytes
                }
                offset += size
            }
        }
        return (received, sent)
    }

    /// Bytes read and written by all block-storage drivers since boot.
    private static func diskBytes() -> (read: UInt64, written: UInt64)? {
        var read: UInt64 = 0, written: UInt64 = 0, found = false
        forEachService("IOBlockStorageDriver") { service in
            guard let stats = property(service, "Statistics") as? [String: Any] else { return }
            if let value = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value { read &+= value; found = true }
            if let value = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value { written &+= value; found = true }
        }
        return found ? (read, written) : nil
    }

    /// The busiest accelerator's reported utilization, if the driver gives one.
    private static func gpuUtilization() -> Double? {
        var highest: Double?
        forEachService("IOAccelerator") { service in
            guard let stats = property(service, "PerformanceStatistics") as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            highest = max(highest ?? 0, value)
        }
        return highest
    }

    /// The startup volume's space, refreshed at most every 30 seconds because
    /// computing purgeable space can take a moment.
    private static func volumeSpace() -> (free: Int64?, total: Int64?) {
        if let volume, Date().timeIntervalSince(volume.at) < 30 { return (volume.free, volume.total) }
        let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        )
        let free = values?.volumeAvailableCapacityForImportantUsage
        let total = values?.volumeTotalCapacity.map(Int64.init)
        volume = (free, total, Date())
        return (free, total)
    }

    private static func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
