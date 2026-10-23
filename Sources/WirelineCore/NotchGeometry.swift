import CoreGraphics

/// Where the island sits on a screen: hugging the hardware notch when there
/// is one, else a small pill centred just below the menu bar.
///
/// All rects are in the screen's own coordinate space (AppKit: origin at the
/// bottom-left, y up), as `NSScreen.frame` reports them.
public struct NotchGeometry: Equatable, Sendable {
    /// The notch (or, without one, the pill's resting rect).
    public var anchor: CGRect
    /// Whether `anchor` is a real hardware notch.
    public var hasNotch: Bool

    /// The pill used on screens without a notch.
    public static let pillSize = CGSize(width: 168, height: 26)
    /// Gap between the menu bar and the pill.
    public static let pillGap: CGFloat = 4
    /// A notch is never this wide; wider means the auxiliary areas are bogus.
    static let maxNotchWidth: CGFloat = 400

    public init(anchor: CGRect, hasNotch: Bool) {
        self.anchor = anchor; self.hasNotch = hasNotch
    }

    /// - Parameters:
    ///   - frame: `NSScreen.frame`.
    ///   - visibleFrame: `NSScreen.visibleFrame` (its top edge is the menu bar's bottom).
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top` (non-zero only with a notch).
    ///   - auxiliaryLeft / auxiliaryRight: `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`,
    ///     the menu-bar strips either side of the notch.
    public static func resolve(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                               auxiliaryLeft: CGRect?, auxiliaryRight: CGRect?) -> NotchGeometry {
        if safeAreaTop > 0, let left = auxiliaryLeft, let right = auxiliaryRight,
           right.minX > left.maxX, right.minX - left.maxX <= maxNotchWidth {
            let notch = CGRect(x: left.maxX, y: frame.maxY - safeAreaTop,
                               width: right.minX - left.maxX, height: safeAreaTop)
            return NotchGeometry(anchor: notch, hasNotch: true)
        }
        // No notch: centre a pill under the menu bar (or the top edge, when
        // the menu bar is hidden and the visible frame reaches it).
        let menuBar = max(0, frame.maxY - visibleFrame.maxY)
        let size = pillSize
        let top = frame.maxY - (menuBar > 0 ? menuBar : 0) - pillGap
        let pill = CGRect(x: (frame.midX - size.width / 2).rounded(), y: top - size.height,
                          width: size.width, height: size.height)
        return NotchGeometry(anchor: pill, hasNotch: false)
    }

    /// The panel's frame: wide and tall enough for the expanded card, its top
    /// edge on the anchor's top, centred on it, kept on screen.
    public func panelFrame(cardSize: CGSize, in frame: CGRect) -> CGRect {
        let width = max(cardSize.width, anchor.width)
        let height = max(cardSize.height, anchor.height)
        var x = (anchor.midX - width / 2).rounded()
        x = min(max(x, frame.minX), frame.maxX - width)
        return CGRect(x: x, y: anchor.maxY - height, width: width, height: height)
    }
}
