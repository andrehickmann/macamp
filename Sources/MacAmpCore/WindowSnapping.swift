import CoreGraphics

/// Window magnetism of the classic player: edges snap together and touching windows move as a group.
public enum WindowSnapping {
    /// Moves `frame` so that edges within `distance` line up with edges of `others` or the screen.
    public static func snap(_ frame: CGRect, to others: [CGRect], screen: CGRect?, distance: CGFloat = 10) -> CGRect {
        var dx: CGFloat?
        var dy: CGFloat?
        func consider(_ delta: CGFloat, _ best: inout CGFloat?) {
            if abs(delta) <= distance, abs(delta) < abs(best ?? .infinity) { best = delta }
        }
        for other in others {
            if frame.maxY + distance >= other.minY, frame.minY - distance <= other.maxY {
                for delta in [other.maxX - frame.minX, other.minX - frame.maxX, other.minX - frame.minX, other.maxX - frame.maxX] {
                    consider(delta, &dx)
                }
            }
            if frame.maxX + distance >= other.minX, frame.minX - distance <= other.maxX {
                for delta in [other.maxY - frame.minY, other.minY - frame.maxY, other.minY - frame.minY, other.maxY - frame.maxY] {
                    consider(delta, &dy)
                }
            }
        }
        if let screen {
            consider(screen.minX - frame.minX, &dx)
            consider(screen.maxX - frame.maxX, &dx)
            consider(screen.minY - frame.minY, &dy)
            consider(screen.maxY - frame.maxY, &dy)
        }
        return frame.offsetBy(dx: dx ?? 0, dy: dy ?? 0)
    }

    /// Indices of all frames connected to `root` through touching edges (including `root`).
    public static func docked(to root: Int, in frames: [CGRect]) -> Set<Int> {
        var group: Set<Int> = [root]
        var queue = [root]
        while let current = queue.popLast() {
            for candidate in frames.indices where !group.contains(candidate) && touching(frames[current], frames[candidate]) {
                group.insert(candidate)
                queue.append(candidate)
            }
        }
        return group
    }

    static func touching(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0
        let sideBySide = abs(a.maxX - b.minX) < 1 || abs(b.maxX - a.minX) < 1
        let stacked = abs(a.maxY - b.minY) < 1 || abs(b.maxY - a.minY) < 1
        return (sideBySide && overlapY) || (stacked && overlapX)
    }
}
