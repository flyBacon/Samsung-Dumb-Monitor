// SPDX-License-Identifier: MPL-2.0
import Foundation

enum ControlPanelLayout {
    static let width: CGFloat = 248

    static func windowOrigin(window: CGRect, surface: CGRect, anchor: CGRect,
                             menuBarBottom: CGFloat, visibleFrame: CGRect) -> CGPoint {
        let left = min(max(anchor.midX - surface.width / 2, visibleFrame.minX + 6),
                       visibleFrame.maxX - surface.width - 6)
        let top = min(menuBarBottom, visibleFrame.maxY) - 2
        // Offset from the actual visible surface, rather than the transparent
        // window frame that also contains the shadow.
        return CGPoint(x: window.minX + left - surface.minX,
                       y: window.minY + top - surface.maxY)
    }
}
