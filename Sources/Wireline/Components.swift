import SwiftUI
import WirelineCore

/// A small colored dot + label reflecting a host's last reachability probe.
struct StatusDot: View {
    let status: HostStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(
                Circle().stroke(.black.opacity(0.08), lineWidth: 0.5)
            )
            .help(text)
    }

    private var color: Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .checking: return .orange
        case .unknown, .none: return .secondary.opacity(0.4)
        }
    }

    var text: String {
        switch status {
        case .online(let ms): return "Online · \(ms) ms"
        case .offline: return "Offline"
        case .checking: return "Checking…"
        case .unknown, .none: return "Unknown"
        }
    }
}

/// A badge showing the authentication method of a host.
struct AuthBadge: View {
    let method: AuthMethod

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private var text: String {
        switch method {
        case .key: return "Key"
        case .password: return "Password"
        case .unknown: return "Auto"
        }
    }
    private var icon: String {
        switch method {
        case .key: return "key.fill"
        case .password: return "lock.fill"
        case .unknown: return "questionmark"
        }
    }
}

extension Host {
    /// A compact "user@hostname:port" descriptor for list rows.
    var connectionSummary: String {
        var s = ""
        if let user, !user.isEmpty { s += "\(user)@" }
        s += connectHostname
        if let port, port != 22 { s += ":\(port)" }
        return s
    }
}
