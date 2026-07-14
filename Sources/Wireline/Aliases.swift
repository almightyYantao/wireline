import WirelineCore

// `Foundation` exposes a legacy `Host` (NSHost) type, which makes an unqualified
// `Host` ambiguous throughout the UI. A single module-level typealias shadows the
// imported one so every view can just say `Host`.
typealias Host = WirelineCore.Host
