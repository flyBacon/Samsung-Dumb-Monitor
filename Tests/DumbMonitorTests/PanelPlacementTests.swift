// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import DumbMonitor

@Test func panelVisibleTopIgnoresTransparentShadowMargin() {
    let anchor = CGRect(x: 900, y: 1056, width: 28, height: 24)
    for padding: CGFloat in [0, 24] {
        let window = CGRect(x: 100, y: 100, width: 248 + padding * 2, height: 120 + padding * 2)
        let surface = window.insetBy(dx: padding, dy: padding)
        let origin = ControlPanelLayout.windowOrigin(window: window, surface: surface, anchor: anchor,
            menuBarBottom: 1056, visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056))
        let movedSurface = surface.offsetBy(dx: origin.x - window.minX, dy: origin.y - window.minY)
        #expect(movedSurface.maxY == 1054)
        #expect(movedSurface.midX == anchor.midX)
    }
}

@Test func panelStaysOnSecondaryScreenNearItsMenuBarEdge() {
    let window = CGRect(x: 0, y: 0, width: 296, height: 168)
    let surface = window.insetBy(dx: 24, dy: 24)
    let origin = ControlPanelLayout.windowOrigin(window: window, surface: surface,
        anchor: CGRect(x: -34, y: 1416, width: 28, height: 24), menuBarBottom: 1416,
        visibleFrame: CGRect(x: -1600, y: 300, width: 1600, height: 1116))
    let movedSurface = surface.offsetBy(dx: origin.x - window.minX, dy: origin.y - window.minY)
    #expect(movedSurface.maxX == -6)
    #expect(movedSurface.maxY == 1414)
}
