// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import DumbMonitor

@Test func volumeHasSixteenNormalStepsAndSafeCeiling() {
    var value = 0
    for _ in 0..<16 { value = ControlPolicy.volume(current: value, delta: 2, limit: 32) }
    #expect(value == 32)
    #expect(ControlPolicy.volume(current: value, delta: 2, limit: 32) == 32)
    #expect(ControlPolicy.volume(current: 0, delta: -2, limit: 32) == 0)
    #expect(ControlPolicy.volume(current: 21, delta: 1, limit: 32) == 22)
    // External remote/app can exceed the preferred cap. No surprising jump.
    #expect(ControlPolicy.volume(current: 60, delta: 2, limit: 32) == 60)
    #expect(ControlPolicy.volume(current: 60, delta: -2, limit: 32) == 58)
}

@Test func brightnessUsesConfigurableIntegerStepsAndFineAdjustment() {
    var value = 0
    for _ in 0..<17 { value = ControlPolicy.brightness(current: value, direction: 1, fine: false) }
    #expect(value == 50)
    #expect(ControlPolicy.brightness(current: 50, direction: 1, fine: true) == 50)
    for _ in 0..<17 { value = ControlPolicy.brightness(current: value, direction: -1, fine: false) }
    #expect(value == 0)
    #expect(ControlPolicy.brightness(current: 0, direction: -1, fine: true) == 0)
    #expect(ControlPolicy.brightness(current: 10, direction: 1, fine: true) == 11)
    #expect(ControlPolicy.brightness(current: 10, direction: 1, fine: false, step: 7) == 17)
    #expect(ControlPolicy.brightness(current: 10, direction: -1, fine: false, step: 7) == 3)
    #expect(ControlPolicy.brightness(current: 48, direction: 1, fine: false, step: 7) == 50)
}

@Test func brightnessFollowsFocusedWindowInsteadOfPointerOnAnotherScreen() {
    let screens = [(id: "S9", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                   (id: "BuiltIn", bounds: CGRect(x: -1600, y: 0, width: 1600, height: 1000))]
    #expect(ControlPolicy.screenForFocus(window: CGRect(x: -1600, y: 400, width: 1000, height: 700),
        pointer: CGPoint(x: 1000, y: 600), screens: screens) == "BuiltIn")
    #expect(ControlPolicy.screenForFocus(window: CGRect(x: 100, y: 50, width: 1600, height: 1000),
        pointer: CGPoint(x: -1000, y: 600), screens: screens) == "S9")
    #expect(ControlPolicy.screenForFocus(window: CGRect(x: -100, y: 400, width: 900, height: 600),
        pointer: CGPoint(x: -1000, y: 600), screens: screens) == "S9")
    #expect(ControlPolicy.screenForFocus(window: nil, pointer: CGPoint(x: -1000, y: 600), screens: screens) == "BuiltIn")
}

@Test func audioOutputChangesDoNotLeakPressesOrStealRepeats() {
    var router = MediaKeyRouting()
    #expect(!router.route(action: .volumeUp, down: true, isRepeat: false, eligible: false).consume)
    #expect(!router.route(action: .volumeUp, down: true, isRepeat: true, eligible: true).consume)
    #expect(router.route(action: .volumeDown, down: true, isRepeat: false, eligible: true).invoke)
    let changed = router.route(action: .volumeDown, down: true, isRepeat: true, eligible: false)
    #expect(changed.consume && !changed.invoke)
    #expect(router.route(action: .volumeDown, down: false, isRepeat: false, eligible: false).consume)
    #expect(!router.route(action: .volumeDown, down: false, isRepeat: false, eligible: true).consume)
}

@Test func holdingMuteDoesNotToggleRepeatedly() {
    var router = MediaKeyRouting()
    #expect(router.route(action: .mute, down: true, isRepeat: false, eligible: true).invoke)
    #expect(!router.route(action: .mute, down: true, isRepeat: true, eligible: true).invoke)
    #expect(router.route(action: .mute, down: false, isRepeat: false, eligible: true).consume)
}
