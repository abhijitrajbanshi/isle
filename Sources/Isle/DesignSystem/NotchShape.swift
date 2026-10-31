import SwiftUI

/// The island silhouette: rounded bottom corners, and a top edge that flares
/// outward into concave shoulders so it reads as part of the bezel.
///
/// Bottom corners use a continuous-curvature (squircle-like) profile, as in
/// Apple's own continuous rounded rectangles, rather than circular arcs.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height / 2))
        let r = max(0, min(radius, (rect.width - 2 * s) / 2, rect.height - s))
        // control-point factor approximating a continuous corner
        let k: CGFloat = 0.28

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s),
                   control1: CGPoint(x: rect.minX + s * 0.62, y: rect.minY),
                   control2: CGPoint(x: rect.minX + s, y: rect.minY + s * 0.38))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        p.addCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
                   control1: CGPoint(x: rect.minX + s, y: rect.maxY - r * k),
                   control2: CGPoint(x: rect.minX + s + r * k, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
                   control1: CGPoint(x: rect.maxX - s - r * k, y: rect.maxY),
                   control2: CGPoint(x: rect.maxX - s, y: rect.maxY - r * k))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: rect.maxX - s, y: rect.minY + s * 0.38),
                   control2: CGPoint(x: rect.maxX - s * 0.62, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
