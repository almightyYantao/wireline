import Foundation

/// ssh-agent protocol constants (draft-miller-ssh-agent).
public enum SSHAgentMessage {
    public static let failure: UInt8 = 5
    public static let success: UInt8 = 6
    public static let requestIdentities: UInt8 = 11
    public static let identitiesAnswer: UInt8 = 12
    public static let signRequest: UInt8 = 13
    public static let signResponse: UInt8 = 14

    /// SIGN_REQUEST flags: for RSA keys, ask for rsa-sha2-256 / rsa-sha2-512
    /// instead of the legacy SHA-1 `ssh-rsa` signature.
    public static let flagRSASHA256: UInt32 = 2
    public static let flagRSASHA512: UInt32 = 4

    /// Largest message we accept (matches OpenSSH's agent limit).
    public static let maxMessageSize = 256 * 1024
}

public enum SSHWireError: Error, Equatable {
    case truncated
    case tooLarge
}

/// Appends SSH wire-format values (RFC 4251 §5) to a byte buffer.
public struct SSHWireWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeByte(_ b: UInt8) { data.append(b) }

    public mutating func writeUInt32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff),
                                 UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    public mutating func writeString(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    public mutating func writeString(_ s: String) { writeString(Data(s.utf8)) }

    /// Two's-complement big-endian integer, minimal length. Inputs are treated as
    /// unsigned magnitudes (every value we encode — r, s, RSA params — is positive),
    /// so a leading 0x00 is added when the top bit is set.
    public mutating func writeMPInt(_ magnitude: Data) {
        var bytes = magnitude.drop { $0 == 0 }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        writeString(Data(bytes))
    }
}

/// Reads SSH wire-format values from a byte buffer, throwing on truncation.
public struct SSHWireReader: Sendable {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = Data(data)   // rebase so indices start at 0
        self.offset = 0
    }

    public var isAtEnd: Bool { offset >= data.count }
    public var remaining: Int { data.count - offset }

    public mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw SSHWireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHWireError.truncated }
        defer { offset += 4 }
        return data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    public mutating func readBytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw SSHWireError.truncated }
        defer { offset += n }
        return Data(data[offset..<offset + n])
    }

    public mutating func readString() throws -> Data {
        let n = try readUInt32()
        guard n <= UInt32(SSHAgentMessage.maxMessageSize) else { throw SSHWireError.tooLarge }
        return try readBytes(Int(n))
    }

    public mutating func readStringUTF8() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    /// Returns the unsigned magnitude (sign byte stripped).
    public mutating func readMPInt() throws -> Data {
        Data(try readString().drop { $0 == 0 })
    }
}
