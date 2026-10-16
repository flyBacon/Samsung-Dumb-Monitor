// SPDX-License-Identifier: MPL-2.0
import Foundation

enum MediaAction: Int, CaseIterable, Sendable {
    // IOKit/hidsystem/ev_keymap.h, NX_KEYTYPE_*.
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7

    var isAudio: Bool { self == .volumeUp || self == .volumeDown || self == .mute }
}

enum ControlPolicy {
    static func volume(current: Int, delta: Int, limit: Int) -> Int {
        // An externally raised volume remains visible. Down must reduce it
        // gradually; Up must never jump it down to our preferred ceiling.
        delta > 0 ? max(current, min(limit, current + delta)) : max(0, current + delta)
    }

    static func brightness(current: Int, direction: Int, fine: Bool, step: Int = 3) -> Int {
        min(50, max(0, current + direction * (fine ? 1 : step)))
    }

    static func screenForFocus(window: CGRect?, pointer: CGPoint, screens: [(id: String, bounds: CGRect)]) -> String? {
        if let window, window.width > 0, window.height > 0 {
            let intersections = screens.map { ($0.id, $0.bounds.intersection(window)) }
            if let largest = intersections.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }),
               !largest.1.isNull, largest.1.width * largest.1.height > 0 { return largest.0 }
        }
        return screens.first { $0.bounds.contains(pointer) }?.id
    }
}

/// Keeps ownership of a whole press/release pair. Routing is decided on the
/// first down, so an audio-device change mid-press cannot leak its key-up.
struct MediaKeyRouting {
    private enum Target { case media, input(MediaInputSlot) }
    private var owned: [MediaAction: Target] = [:]

    mutating func route(action: MediaAction, down: Bool, isRepeat: Bool,
                        eligible: Bool, inputAction: MediaInputSlot? = nil)
        -> (consume: Bool, invoke: Bool, input: MediaInputSlot?) {
        if !down { return (owned.removeValue(forKey: action) != nil, false, nil) }
        if let target = owned[action] {
            switch target {
            case .input: return (true, false, nil)
            case .media: return (true, isRepeat && eligible && action != .mute, nil)
            }
        }
        // Never take over a press that began in another handler or before this
        // feature was enabled, even if its modifiers change while held.
        guard !isRepeat else { return (false, false, nil) }
        if let inputAction {
            owned[action] = .input(inputAction)
            return (true, false, inputAction)
        }
        if eligible { owned[action] = .media; return (true, true, nil) }
        return (false, false, nil)
    }
}
