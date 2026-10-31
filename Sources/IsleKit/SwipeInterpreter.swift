import CoreGraphics

/// Turns raw two-finger scroll deltas into one discrete gesture per swipe,
/// the way the iPhone island responds to a flick rather than to distance.
public struct SwipeInterpreter: Sendable {
    public enum Gesture: Equatable, Sendable { case up, down, left, right }

    public var threshold: CGFloat
    private var accumulated: CGVector = .zero
    private var fired = false

    public init(threshold: CGFloat = 46) { self.threshold = threshold }

    /// Call when a new trackpad gesture begins.
    public mutating func reset() {
        accumulated = .zero
        fired = false
    }

    /// Feed one scroll event (deltas as the user's fingers moved, i.e. with
    /// natural scrolling already undone). Returns a gesture at most once per swipe.
    public mutating func feed(dx: CGFloat, dy: CGFloat) -> Gesture? {
        guard !fired else { return nil }
        accumulated.dx += dx
        accumulated.dy += dy
        let horizontal = abs(accumulated.dx), vertical = abs(accumulated.dy)
        guard max(horizontal, vertical) >= threshold else { return nil }
        // require a clear dominant axis so diagonal drags don't misfire
        if horizontal > vertical * 1.4 {
            fired = true
            return accumulated.dx > 0 ? .right : .left
        }
        if vertical > horizontal * 1.4 {
            fired = true
            return accumulated.dy > 0 ? .down : .up
        }
        return nil
    }
}
