import Combine
import Foundation
import Testing
@testable import PersonalIslandPresentation

private func counters(busy: UInt64 = 0, idle: UInt64 = 0, netIn: UInt64? = 0, netOut: UInt64? = 0,
                      read: UInt64? = 0, written: UInt64? = 0) -> StatsCounters {
    StatsCounters(cpu: .init(busy: busy, idle: idle), gpuPercent: nil, memoryUsed: 4, memoryTotal: 16,
                  networkIn: netIn, networkOut: netOut, diskRead: read, diskWritten: written,
                  diskFree: 100, diskTotal: 500)
}

@Test func ratesAndCpuComeFromTheDifferenceBetweenSamples() {
    let reading = SystemStats.reading(
        from: counters(busy: 100, idle: 300, netIn: 1_000, netOut: 0, read: 0, written: 500),
        to: counters(busy: 130, idle: 370, netIn: 5_000, netOut: 2_000, read: 8_000, written: 500),
        seconds: 2
    )
    #expect(reading.cpuPercent == 30)
    #expect(reading.networkInPerSecond == 2_000 && reading.networkOutPerSecond == 1_000)
    #expect(reading.diskReadPerSecond == 4_000 && reading.diskWritePerSecond == 0)
    #expect(reading.memoryPercent == 25)
    #expect(reading.diskFree == 100 && reading.diskTotal == 500)
}

@Test func theFirstSampleAndBackwardCountersGiveNoRateInsteadOfASpike() {
    let first = SystemStats.reading(from: nil, to: counters(busy: 10, idle: 10, netIn: 99), seconds: 0)
    #expect(first.cpuPercent == nil && first.networkInPerSecond == nil && first.diskReadPerSecond == nil)
    #expect(first.memoryPercent == 25)   // levels need only one sample

    let reset = SystemStats.reading(from: counters(busy: 500, idle: 500, netIn: 9_000, read: 9_000),
                                    to: counters(busy: 10, idle: 900, netIn: 100, read: 9_500), seconds: 1)
    #expect(reset.cpuPercent == nil && reset.networkInPerSecond == nil)
    #expect(reset.diskReadPerSecond == 500)

    let zeroInterval = SystemStats.reading(from: counters(netIn: 0), to: counters(netIn: 10), seconds: 0)
    #expect(zeroInterval.networkInPerSecond == nil)
    let idle = SystemStats.reading(from: counters(busy: 5, idle: 5), to: counters(busy: 5, idle: 5), seconds: 1)
    #expect(idle.cpuPercent == nil)      // no ticks elapsed: unknown, not 0%
}

@Test func missingAndImplausibleValuesAreShownAsUnavailable() {
    var sample = counters(netIn: nil, read: nil)
    sample.gpuPercent = .nan
    sample.memoryUsed = 20                // more than total
    sample.diskFree = -1
    sample.diskTotal = 0
    let reading = SystemStats.reading(from: counters(), to: sample, seconds: 1)
    #expect(reading.gpuPercent == nil && reading.memoryPercent == nil && reading.memoryUsed == nil)
    #expect(reading.networkInPerSecond == nil && reading.diskReadPerSecond == nil)
    #expect(reading.diskFree == nil && reading.diskTotal == nil)
    sample.gpuPercent = 140
    #expect(SystemStats.reading(from: nil, to: sample, seconds: 0).gpuPercent == 100)
}

@Test func valuesReadNaturally() {
    #expect(SystemStats.percentText(12.6) == "13%")
    #expect(SystemStats.percentText(nil) == "—")
    #expect(SystemStats.bytesText(512) == "512 B")
    #expect(SystemStats.bytesText(3_400_000) == "3.4 MB")
    #expect(SystemStats.bytesText(250_000_000_000) == "250 GB")
    #expect(SystemStats.bytesText(17_179_869_184, binary: true) == "16.0 GB")
    #expect(SystemStats.bytesText(-5) == "—")
    #expect(SystemStats.rateText(1_500) == "1.5 KB/s")
    #expect(SystemStats.rateText(nil) == "—")
}

// MARK: - Sampling lifecycle

private final class Flag: @unchecked Sendable { var cancelled = false }

@MainActor
private final class FakeSampler {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var next = counters()
    var samples = 0
    var ticks: [(action: @MainActor () -> Void, flag: Flag)] = []

    func controller() -> StatsController {
        StatsController(environment: .init(
            sample: { [unowned self] in
                self.samples += 1
                return self.next
            },
            now: { [unowned self] in self.now },
            repeating: { [unowned self] _, action in
                let flag = Flag()
                self.ticks.append((action, flag))
                return AnyCancellable { flag.cancelled = true }
            }
        ))
    }

    var running: Int { ticks.filter { !$0.flag.cancelled }.count }

    func tick(busy: UInt64, idle: UInt64) {
        now = now.addingTimeInterval(1)
        next = counters(busy: busy, idle: idle)
        ticks.last?.action()
    }
}

@Test @MainActor func samplingRunsOnlyBetweenStartAndStopAndForgetsEverything() {
    let sampler = FakeSampler()
    let controller = sampler.controller()
    #expect(sampler.samples == 0 && sampler.running == 0)
    controller.start()
    controller.start()
    #expect(sampler.samples == 1 && sampler.running == 1)
    sampler.tick(busy: 50, idle: 50)
    #expect(controller.reading?.cpuPercent == 50)
    #expect(controller.cpuHistory == [50])
    controller.stop()
    #expect(sampler.running == 0 && !controller.isSampling)
    #expect(controller.reading == nil && controller.cpuHistory.isEmpty && controller.memoryHistory.isEmpty)
    let before = sampler.samples
    sampler.ticks[0].action()            // stale tick after stop
    #expect(sampler.samples == before && controller.reading == nil)
}

@Test @MainActor func restartingDoesNotComputeRatesAcrossTheGap() {
    let sampler = FakeSampler()
    let controller = sampler.controller()
    controller.start()
    controller.stop()
    sampler.now = sampler.now.addingTimeInterval(3_600)
    sampler.next = counters(busy: 9_999, idle: 1)
    controller.start()
    #expect(controller.reading?.cpuPercent == nil)
}

@Test @MainActor func graphsKeepOnlyTheMostRecentMinute() {
    let sampler = FakeSampler()
    let controller = sampler.controller()
    controller.start()
    for step in 1...(SystemStats.historyLength + 10) {
        sampler.tick(busy: UInt64(step * 10), idle: UInt64(step * 10))
    }
    #expect(controller.cpuHistory.count == SystemStats.historyLength)
    #expect(controller.memoryHistory.count == SystemStats.historyLength)
    #expect(controller.networkHistory.count == SystemStats.historyLength)
}
