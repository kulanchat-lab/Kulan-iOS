//
// Direction-locked pan recognizer, cloned from Signal-iOS (SignalUI/Views/DirectionalPanGestureRecognizer.swift,
// AGPL-3.0). It only begins if the first movement is in the allowed direction and cancels itself if the
// cross-axis dominates. We pair it with scrollView.panGestureRecognizer.require(toFail:) so the cube page
// swipe and the swipe-down dismiss are mutually exclusive.
//

import UIKit.UIGestureRecognizerSubclass

struct PanDirection: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let left = PanDirection(rawValue: 1 << 0)
    static let right = PanDirection(rawValue: 1 << 1)
    static let up = PanDirection(rawValue: 1 << 2)
    static let down = PanDirection(rawValue: 1 << 3)

    static let horizontal: PanDirection = [.left, .right]
    static let vertical: PanDirection = [.up, .down]
    static let any: PanDirection = [.left, .right, .up, .down]
}

final class DirectionalPanGestureRecognizer: UIPanGestureRecognizer {

    let direction: PanDirection
    private var startLocation: CGPoint = .zero

    init(direction: PanDirection, target: AnyObject, action: Selector) {
        self.direction = direction
        super.init(target: target, action: action)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        startLocation = touches.first?.location(in: view) ?? .zero
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Classify from the CUMULATIVE movement since touch-down (standard signs: +y = down), and only once
        // it's a deliberate move (>= 12pt). The old code decided from a single noisy frame and failed on the
        // first jittery pixel — that's why swipe-down-to-close only fired "sometimes".
        if state == .possible {
            guard let touch = touches.first else { return }
            let loc = touch.location(in: view)
            let dx = loc.x - startLocation.x
            let dy = loc.y - startLocation.y
            guard hypot(dx, dy) >= 12 else { return }   // wait for a clear gesture before deciding

            let isSatisfied: Bool = {
                if abs(dy) >= abs(dx) {
                    if direction.contains(.up), dy < 0 { return true }
                    if direction.contains(.down), dy > 0 { return true }
                } else {
                    if direction.contains(.left), dx < 0 { return true }
                    if direction.contains(.right), dx > 0 { return true }
                }
                return false
            }()

            // Wrong axis → fail now so the scroll view / cube that required(toFail:) us can take over.
            guard isSatisfied else { state = .failed; return }
        }

        super.touchesMoved(touches, with: event)
    }
}
