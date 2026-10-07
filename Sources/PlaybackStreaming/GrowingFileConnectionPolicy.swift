import CryptoKit
import Foundation
import Security

/// **How one server is talked to**: extra request headers and the certificates the user trusted for a
/// self-hosted server (Jellyfin, Subsonic) whose certificate the system cannot verify.
///
/// Both apply to the origin of the source's `url` only (same scheme, host and port). A redirect to
/// another origin (a CDN) is sent without the headers and evaluated by the system's default trust.
public struct GrowingFileConnectionPolicy: Sendable, Equatable {
    /// The read failure reason (`StreamByteReaderError.transport`) when the system refuses the
    /// origin's certificate and its leaf is not one of ``trustedLeafSHA256``. Never retried: a retry
    /// meets the same certificate.
    public static let untrustedCertificateReason = "untrusted_certificate"

    /// Sent on every request to the origin, after the source's `authHeaders` (these win a clash).
    public var headers: [String: String]

    /// SHA-256 fingerprints of whole leaf certificates (DER) the user trusted for the origin: a trust
    /// exception, not a restriction. The system's evaluation runs first, and a chain it trusts is
    /// accepted whatever these hold. A chain it refuses is accepted only when the leaf (the
    /// certificate the server proved it holds the key of) has one of these fingerprints; the
    /// system's roots, expiry and host name check are then waived for that leaf. Otherwise the read
    /// fails with ``untrustedCertificateReason``. Empty (the default) leaves the system's evaluation
    /// alone.
    ///
    /// Hex in any case, with or without separators (`AB:CD…`); kept in the form
    /// ``leafSHA256(of:)`` returns, upper-case hex with no separators.
    public var trustedLeafSHA256: Set<String> {
        get { normalizedPins }
        set { normalizedPins = Set(newValue.map(Self.normalizedFingerprint)) }
    }

    private var normalizedPins: Set<String>

    public init(headers: [String: String] = [:], trustedLeafSHA256: Set<String> = []) {
        self.headers = headers
        self.normalizedPins = Set(trustedLeafSHA256.map(Self.normalizedFingerprint))
    }

    /// The fingerprint of a DER certificate as ``trustedLeafSHA256`` keeps it: the SHA-256 of the
    /// whole certificate, upper-case hex, no separators.
    public static func leafSHA256(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    static func normalizedFingerprint(_ fingerprint: String) -> String {
        String(fingerprint.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).uppercased()
    }

    /// How the origin's server trust challenge is answered.
    enum TrustDecision: Equatable {
        /// The system trusts the chain: its default handling applies.
        case systemDefault
        /// The system refuses the chain, but the user trusted its leaf: accepted.
        case acceptTrustedLeaf
        /// The system refuses the chain and the leaf is not trusted: the read fails.
        case reject
    }

    /// The decision for a chain the system did or did not trust, from its leaf (DER) alone: a
    /// trusted certificate further up a chain proves nothing, as anyone can present it.
    func decision(systemTrusted: Bool, leafDER: Data?) -> TrustDecision {
        if systemTrusted { return .systemDefault }
        guard let leafDER, normalizedPins.contains(Self.leafSHA256(of: leafDER)) else { return .reject }
        return .acceptTrustedLeaf
    }

    /// Evaluates `trust` (blocking: never on the main thread), then decides from its leaf.
    func decision(for trust: SecTrust) -> TrustDecision {
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        return decision(systemTrusted: systemTrusted, leafDER: leaf.map { SecCertificateCopyData($0) as Data })
    }
}

extension URL {
    /// Same scheme, host and port (the scheme's default when none is given), case-insensitively.
    func hasSameOrigin(as other: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            return (scheme, host, url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0))
        }
        guard let a = origin(self), let b = origin(other) else { return false }
        return a == b
    }
}
