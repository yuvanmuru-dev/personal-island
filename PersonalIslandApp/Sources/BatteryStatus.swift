/*
 * Personal Island — battery and charging model and lifecycle.
 * Written for this personal project; no upstream file copied.
 */

import Foundation
import IOKit.ps

/// One reading of the internal battery. Nothing here is stored or sent.
struct PowerSnapshot: Equatable {
    /// 0...100.
    let percent: Int
    let isPluggedIn: Bool
    let isCharging: Bool
    /// The system reports the battery as charged (it may stop below 100%
    /// with optimized charging).
    let isCharged: Bool
    /// Minutes, when macOS has an estimate.
    let minutesToEmpty: Int?
    let minutesToFull: Int?

    /// Reads an internal-battery description from IOPSGetPowerSourceDescription.
    /// Other power sources (UPS units, accessories) and implausible values are
    /// rejected, so a damaged reading never produces an alert.
    init?(description: [String: Any]) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool ?? true,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              maximum > 0, current >= 0 else { return nil }
        let state = description[kIOPSPowerSourceStateKey] as? String
        self.init(
            percent: min(100, Int((Double(current) / Double(maximum) * 100).rounded())),
            isPluggedIn: state == kIOPSACPowerValue,
            isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
            isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
            minutesToEmpty: Self.minutes(description[kIOPSTimeToEmptyKey]),
            minutesToFull: Self.minutes(description[kIOPSTimeToFullChargeKey])
        )
    }

    init(percent: Int, isPluggedIn: Bool, isCharging: Bool, isCharged: Bool = false,
         minutesToEmpty: Int? = nil, minutesToFull: Int? = nil) {
        self.percent = min(100, max(0, percent))
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
    }

    /// macOS reports -1 while it is still estimating.
    private static func minutes(_ value: Any?) -> Int? {
        guard let minutes = value as? Int, minutes > 0, minutes < 24 * 60 else { return nil }
        return minutes
    }
}

/// A short-lived notice shown beside the notch.
enum BatteryActivity: Equatable {
    case pluggedIn(percent: Int)
    case unplugged(percent: Int)
    case low(percent: Int)
    case charged(percent: Int)

    var percent: Int {
        switch self {
        case .pluggedIn(let p), .unplugged(let p), .low(let p), .charged(let p): p
        }
    }
}

enum BatteryStatus: Equatable {
    case off
    /// This Mac reports no internal battery.
    case noBattery
    case ready
}

enum BatteryEvents {
    /// Low-battery alerts fire when the level falls to each of these.
    static let lowThresholds = [20, 10]

    /// What changed between two readings. The first reading after starting
    /// never produces a notice, so launching or turning the switch on is quiet.
    static func activity(from old: PowerSnapshot, to new: PowerSnapshot,
                         lowAlerts: Bool, chargedAlert: Bool) -> BatteryActivity? {
        if new.isPluggedIn != old.isPluggedIn {
            return new.isPluggedIn ? .pluggedIn(percent: new.percent) : .unplugged(percent: new.percent)
        }
        if chargedAlert, new.isPluggedIn, new.isCharged || new.percent == 100,
           !(old.isCharged || old.percent == 100) {
            return .charged(percent: new.percent)
        }
        if lowAlerts, !new.isPluggedIn,
           lowThresholds.contains(where: { old.percent > $0 && new.percent <= $0 }) {
            return .low(percent: new.percent)
        }
        return nil
    }
}

/// Starts and stops all battery work for the feature switch. Platform access
/// is injected so tests never read the real power source.
@MainActor
final class BatteryController {
    struct Environment {
        /// nil when there is no internal battery.
        var read: @MainActor () -> PowerSnapshot?
        /// Calls the handler whenever macOS reports a power-source change.
        var observe: @MainActor (_ handler: @escaping @MainActor () -> Void) -> AnyObject?
        var stopObserving: @MainActor (AnyObject) -> Void
    }

    private(set) var status: BatteryStatus = .off
    private(set) var snapshot: PowerSnapshot?
    var lowAlertsEnabled = true
    var chargedAlertEnabled = true
    var onChange: (@MainActor () -> Void)?
    var onActivity: (@MainActor (BatteryActivity) -> Void)?

    private let environment: Environment
    private var observation: AnyObject?
    private var isActive = false

    init(environment: Environment) {
        self.environment = environment
    }

    var isRunning: Bool { isActive }

    func start() {
        guard !isActive else { return }
        isActive = true
        observation = environment.observe { [weak self] in self?.refresh() }
        apply(environment.read(), announce: false)
    }

    /// Ends observation and forgets the last reading.
    func stop() {
        guard isActive else { return }
        isActive = false
        if let observation { environment.stopObserving(observation) }
        observation = nil
        snapshot = nil
        status = .off
        onChange?()
    }

    func refresh() {
        guard isActive else { return }
        apply(environment.read(), announce: true)
    }

    private func apply(_ reading: PowerSnapshot?, announce: Bool) {
        let previous = snapshot
        let newStatus: BatteryStatus = reading == nil ? .noBattery : .ready
        guard reading != previous || newStatus != status else { return }
        snapshot = reading
        status = newStatus
        onChange?()
        if announce, let previous, let reading,
           let activity = BatteryEvents.activity(from: previous, to: reading,
                                                 lowAlerts: lowAlertsEnabled, chargedAlert: chargedAlertEnabled) {
            onActivity?(activity)
        }
    }
}
