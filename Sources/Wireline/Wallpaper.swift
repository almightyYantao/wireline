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
            // The layer only shows an image / video layer; nothing to redraw on resize.
            layerContentsRedrawPolicy = .never
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        func apply(_ path: String?) {
            guard currentPath != .some(path) else { return }
            currentPath = .some(path)
            teardownVideo()
            edgeColor = nil
            layer?.contents = nil

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
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                Task { [weak self] in
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.maximumSize = CGSize(width: 64, height: 64)
                    guard let (frame, _) = try? await gen.image(at: .zero) else { return }
                    let color = Self.averageColor(of: frame)
                    await MainActor.run {
                        guard let self, self.currentPath == .some(path) else { return }
                        self.edgeColor = color
                        self.paintWindowBackground()
                    }
                }
            } else if let image = NSImage(contentsOfFile: path) {
                layer?.contents = image
                layer?.contentsGravity = .resizeAspectFill
                edgeColor = image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(Self.averageColor)
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

        /// Behind the image / video too: whatever a resize uncovers before the
        /// wallpaper catches up is this colour, not black.
        private func paintWindowBackground() {
            let color = edgeColor ?? NSColor(Palette.shared.bg)
            layer?.backgroundColor = color.cgColor
            window?.backgroundColor = color
        }

        private nonisolated static func averageColor(of cg: CGImage) -> NSColor? {
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
            fitPlayerLayer()
        }

        // An AVPlayerLayer frame change animates implicitly (¼ s), which left
        // the video trailing the window edge during a live resize.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fitPlayerLayer()
        }

        private func fitPlayerLayer() {
            guard let playerLayer, playerLayer.frame != bounds else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
