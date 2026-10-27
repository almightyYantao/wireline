import Foundation

/// How long an in-app notification card stays up.
public enum CardLinger: String, CaseIterable, Sendable {
    case standard, s5, s10, s30, s90, untilClosed

    /// Seconds, or nil for "until closed".
    public var seconds: TimeInterval? {
        switch self {
        case .standard: 5
        case .s5: 5
        case .s10: 10
        case .s30: 30
        case .s90: 90
        case .untilClosed: nil
        }
    }

    /// Unknown or missing stored values fall back to `.standard`.
    public init(stored: String?) {
        self = stored.flatMap(CardLinger.init(rawValue:)) ?? .standard
    }
}

public struct NotificationCard: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    public var session: UUID?
    /// Display time left; nil means it stays until closed.
    public var remaining: TimeInterval?

    public init(id: UUID = UUID(), title: String, body: String, session: UUID?, linger: CardLinger) {
        self.id = id; self.title = title; self.body = body; self.session = session
        remaining = linger.seconds
    }
}

/// The cards on screen plus a backlog. Only the visible ones count down,
/// and not while `paused` (pointer hovering). Closing a card only removes it.
public struct CardQueue: Equatable, Sendable {
    public var maxVisible: Int
    public private(set) var visible: [NotificationCard] = []
    public private(set) var pending: [NotificationCard] = []
    public var paused = false

    public init(maxVisible: Int = 3) { self.maxVisible = max(1, maxVisible) }

    public mutating func push(_ card: NotificationCard) {
        pending.append(card)
        promote()
    }

    public mutating func close(_ id: UUID) {
        visible.removeAll { $0.id == id }
        pending.removeAll { $0.id == id }
        promote()
    }

    /// Advance the visible cards' clocks by `elapsed`; drop expired ones.
    public mutating func tick(_ elapsed: TimeInterval) {
        guard !paused, elapsed > 0 else { return }
        for i in visible.indices {
            if let r = visible[i].remaining { visible[i].remaining = r - elapsed }
        }
        visible.removeAll { ($0.remaining ?? 1) <= 0 }
        promote()
    }

    /// Seconds until the next visible card expires, if any is counting.
    public var nextExpiry: TimeInterval? {
        paused ? nil : visible.compactMap(\.remaining).min().map { max(0, $0) }
    }

    public var isEmpty: Bool { visible.isEmpty && pending.isEmpty }

    private mutating func promote() {
        while visible.count < maxVisible, !pending.isEmpty { visible.append(pending.removeFirst()) }
    }
}
