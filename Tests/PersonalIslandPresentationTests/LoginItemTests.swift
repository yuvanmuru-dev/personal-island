import Foundation
import Testing
@testable import PersonalIslandPresentation

private struct Refused: Error {}

@MainActor
private final class FakeLoginItems {
    var state: LoginItemState = .off
    /// What macOS reports right after registering.
    var afterRegister: LoginItemState = .on
    var failNext = false
    var calls: [String] = []

    func controller() -> LoginItemController {
        LoginItemController(environment: .init(
            state: { [unowned self] in self.state },
            register: { [unowned self] in
                self.calls.append("register")
                if self.failNext { self.failNext = false; throw Refused() }
                self.state = self.afterRegister
            },
            unregister: { [unowned self] in
                self.calls.append("unregister")
                if self.failNext { self.failNext = false; throw Refused() }
                self.state = .off
            }
        ))
    }
}

@Test @MainActor func turningOnAndOffRegistersAndRemovesTheLoginItem() {
    let macOS = FakeLoginItems()
    let controller = macOS.controller()
    #expect(!controller.isOn)
    controller.setEnabled(true)
    controller.setEnabled(true)                     // already on: nothing more
    #expect(controller.state == .on && macOS.calls == ["register"])
    controller.setEnabled(false)
    #expect(controller.state == .off && macOS.calls == ["register", "unregister"])
}

@Test @MainActor func waitingForApprovalCountsAsOnAndIsNotRegisteredTwice() {
    let macOS = FakeLoginItems()
    macOS.afterRegister = .needsApproval
    let controller = macOS.controller()
    controller.setEnabled(true)
    #expect(controller.state == .needsApproval && controller.isOn)
    controller.setEnabled(true)
    #expect(macOS.calls == ["register"])
    macOS.state = .on                               // approved in System Settings
    controller.refresh()
    #expect(controller.state == .on)
}

@Test @MainActor func aRefusalShowsAMessageAndTheSwitchShowsMacOSsRealState() {
    let macOS = FakeLoginItems()
    let controller = macOS.controller()
    macOS.failNext = true
    controller.setEnabled(true)
    #expect(controller.state == .off && controller.message != nil)
    controller.setEnabled(true)
    #expect(controller.state == .on && controller.message == nil)
}

@Test @MainActor func changesMadeInSystemSettingsAreReadNotRemembered() {
    let macOS = FakeLoginItems()
    macOS.state = .on
    let controller = macOS.controller()
    #expect(controller.isOn)
    var changes = 0
    controller.onChange = { changes += 1 }
    macOS.state = .off                              // removed under Login Items
    controller.refresh()
    controller.refresh()
    #expect(!controller.isOn && changes == 1)
    controller.setEnabled(false)                    // already off: no call
    #expect(macOS.calls.isEmpty)
}
