import Foundation
import Security

/// **How one server is talked to**: extra request headers and an optional pinned certificate, for a
/// self-hosted server (Jellyfin, Subsonic) whose certificate no system root signed.
///
/// Both apply to the origin of the source's `url` only (same scheme, host and port). A redirect to
/// another origin (a CDN) is sent without the headers and evaluated by the system's default trust.
public struct GrowingFileConnectionPolicy: Sendable, Equatable {
    /// The read failure reason (`StreamByteReaderError.transport`) when the server's certificate is
    /// not one of ``pinnedCertificates``. Never retried: a retry meets the same certificate.
    public static let pinMismatchReason = "certificate_pin_mismatch"

    /// Sent on every request to the origin, after the source's `authHeaders` (these win a clash).
    public var headers: [String: String]
    /// DER-encoded certificates. When not empty, the origin's TLS connection is accepted if and only
    /// if one certificate of its chain is byte-identical to one of these; the system's trust
    /// evaluation (and so its roots, expiry and host name check) is replaced for that origin. Empty
    /// (the default) leaves the system's evaluation alone.
    public var pinnedCertificates: [Data]

    public init(headers: [String: String] = [:], pinnedCertificates: [Data] = []) {
        self.headers = headers
        self.pinnedCertificates = pinnedCertificates
    }

    /// Whether a server's chain (DER, leaf first) satisfies the pin; true when nothing is pinned.
    func accepts(chain: [Data]) -> Bool {
        pinnedCertificates.isEmpty || chain.contains { pinnedCertificates.contains($0) }
    }

    func accepts(trust: SecTrust) -> Bool {
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return accepts(chain: chain.map { SecCertificateCopyData($0) as Data })
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
