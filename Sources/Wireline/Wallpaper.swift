import SwiftUI
import AVFoundation
import AppKit

/// App-wide background wallpaper: a still image or a looping muted video (mp4 /
/// mov / m4v). Sits behind the whole window; panels are drawn semi-transparent
/// on top so it shows through.
///
/// The wallpaper itself isn't laid out by SwiftUI: during a live window resize
/// SwiftUI places its views a frame late, so the newly exposed edge flashed the
/// window background before the wallpaper caught up. Instead this view only
/// marks the spot; the real wallpaper is an AppKit view behind the window's
/// content that autoresizes with the window frame, in the same transaction.
struct WallpaperView: NSViewRepresentable {
    let path: String?

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) { nsView.path = .some(path) }

    final class Anchor: NSView {
        var path: String?? { didSet { install() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func install() {
            guard let path, let frameView = window?.contentView?.superview,
                  let content = window?.contentView else { return }
            let wall = frameView.subviews.lazy.compactMap { $0 as? WallpaperNSView }.first ?? {
                let v = WallpaperNSView(frame: frameView.bounds)
                v.autoresizingMask = [.width, .height]
                frameView.addSubview(v, positioned: .below, relativeTo: content)
                return v
            }()
            wall.apply(path)
        }
    }

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
            if path == nil { layer?.backgroundColor = NSColor(Palette.shared.bg).cgColor }
            guard currentPath != .some(path) else { return }
            currentPath = .some(path)
            teardownVideo()
            layer?.contents = nil
            // Without a wallpaper the theme background shows (not a fixed dark).
            layer?.backgroundColor = NSColor(Palette.shared.bg).cgColor

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
            }
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

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // Follow the window frame without implicit layer animations, so a live
        // resize never shows the image lagging behind the edge.
        override func setFrameSize(_ newSize: NSSize) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            super.setFrameSize(newSize)
            playerLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
