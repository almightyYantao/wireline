import SwiftUI
import AVFoundation
import AppKit

/// App-wide background wallpaper: a still image or a looping muted video (mp4 /
/// mov / m4v). Sits behind the whole window; panels are drawn semi-transparent
/// on top so it shows through.
struct WallpaperView: NSViewRepresentable {
    let path: String?
    /// The wallpaper's average colour, for window backgrounds (see paintWindowBackground).
    @MainActor static var edgeColor: NSColor?

    func makeNSView(context: Context) -> WallpaperNSView { WallpaperNSView() }
    func updateNSView(_ nsView: WallpaperNSView, context: Context) { nsView.apply(path) }

    final class WallpaperNSView: NSView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var playerLayer: AVPlayerLayer?
        private var currentPath: String??  // double-optional to detect "not yet applied"
        private var observers: [NSObjectProtocol] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .duringViewResize
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        func apply(_ path: String?) {
            guard currentPath != .some(path) else { return }
            currentPath = .some(path)
            teardownVideo()
            edgeColor = nil
            layer?.contents = nil
            layer?.backgroundColor = NSColor(red: 0.039, green: 0.055, blue: 0.039, alpha: 1).cgColor

            guard let path else { return }
            let ext = (path as NSString).pathExtension.lowercased()
            if ["mp4", "mov", "m4v"].contains(ext) {
                let item = AVPlayerItem(url: URL(fileURLWithPath: path))
                let queue = AVQueuePlayer()
                queue.isMuted = true
                // A wallpaper must never keep the display awake.
                queue.preventsDisplaySleepDuringVideoPlayback = false
                looper = AVPlayerLooper(player: queue, templateItem: item)
                let pl = AVPlayerLayer(player: queue)
                pl.videoGravity = .resizeAspectFill
                pl.frame = bounds
                layer?.addSublayer(pl)
                player = queue
                playerLayer = pl
                updatePlayback()   // play only if currently visible
            } else if let image = NSImage(contentsOfFile: path) {
                layer?.contents = image
                layer?.contentsGravity = .resizeAspectFill
                edgeColor = Self.averageColor(of: image)
            }
            paintWindowBackground()
        }

        /// During a live resize SwiftUI lays this view out a frame behind the
        /// window edge, so the window's own background shows along the new
        /// strip for a moment. Make that background the wallpaper's average
        /// colour, so the strip blends in instead of flashing dark.
        private var edgeColor: NSColor? {
            didSet { WallpaperView.edgeColor = edgeColor }
        }

        private func paintWindowBackground() {
            guard let window else { return }
            window.backgroundColor = edgeColor ?? NSColor(Palette.shared.bg)
        }

        private static func averageColor(of image: NSImage) -> NSColor? {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255, alpha: 1)
        }

        private func teardownVideo() {
            player?.pause()
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            looper = nil
            player = nil
        }

        // MARK: - Pause while off-screen

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard let window else { updatePlayback(); return }
            // After WindowChromeController, which sets the theme colour.
            DispatchQueue.main.async { [weak self] in self?.paintWindowBackground() }
            let nc = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification
            ]
            for name in names {
                observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePlayback() }
                })
            }
            updatePlayback()
        }

        /// Play only when the window is actually visible on screen; pause when it's
        /// occluded, minimized, hidden, or on another space — so an animated
        /// wallpaper costs nothing when the user can't see it.
        private func updatePlayback() {
            guard let player else { return }
            let visible = window?.occlusionState.contains(.visible) ?? false
            if visible { player.play() } else { player.pause() }
        }

        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
        }
    }
}
