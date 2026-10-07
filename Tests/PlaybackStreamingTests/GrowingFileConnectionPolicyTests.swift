@testable import PlaybackStreaming
import Security
import XCTest

/// The trust decision over real `SecTrust`s. The two certificates are self-signed P-256 leaves for
/// `localhost` (SAN, serverAuth, CA:FALSE, valid 2026-10-07 to 2028-12-15), made once with
///
///     openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout k.pem \
///       -out c.pem -days 800 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" \
///       -addext "extendedKeyUsage=serverAuth" -addext "basicConstraints=critical,CA:FALSE"
///     openssl x509 -in c.pem -outform DER | base64
///
/// and the keys thrown away. The fingerprints are `openssl x509 -noout -fingerprint -sha256`.
final class GrowingFileConnectionPolicyTests: XCTestCase {
    private static let pinnedDER = Data(base64Encoded: """
        MIIBhDCCASqgAwIBAgIUV9uVg9Gca3M0cxDXO466lGHw+H0wCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4X\
        DTI2MTAwNzIyMDYzMFoXDTI4MTIxNTIyMDYzMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D\
        AQcDQgAEPbB2TKLL5s+TDcVaP+m9zzanust+qI4+XdLlzwxUioTiS92fTQUn/oLEY8LpCc/KWgKOJ1NxiID9ywPU5K2SNaNa\
        MFgwHQYDVR0OBBYEFFzVqcY3Q7pJL1Fxwq60Ia3ba4tHMBQGA1UdEQQNMAuCCWxvY2FsaG9zdDATBgNVHSUEDDAKBggrBgEF\
        BQcDATAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0gAMEUCIHuee6E4Fsg5OUiIMRuYLtDHToSLQbHR7+2DXyiXJ7BAAiEA\
        3PZ/SlUh+4Ny1l8zOTF43Vv7yQxKE20YBySUo00lfEs=
        """)!
    private static let pinnedSHA256 = "FF:81:5C:B3:5B:F1:58:8F:8E:5E:DF:30:02:5A:51:F0:98:59:BA:0D:9D:8D:EF:12:70:0F:93:9F:B8:D4:46:9C"

    private static let attackerDER = Data(base64Encoded: """
        MIIBhDCCASqgAwIBAgIUKvya+u+kgLEubyutq5wKXBzVFdcwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4X\
        DTI2MTAwNzIyMDYzMFoXDTI4MTIxNTIyMDYzMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D\
        AQcDQgAEylopgGmqZNiUsws6/4I1th/n+14/zgjrNrd7W7EL5uABD/BmKVGFIePyKcBwb1yNHNVSIicxVYu8hq9LDh3iMKNa\
        MFgwHQYDVR0OBBYEFOnJ/9HjQ1jSU541ko5aWxsJxEI5MBQGA1UdEQQNMAuCCWxvY2FsaG9zdDATBgNVHSUEDDAKBggrBgEF\
        BQcDATAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0gAMEUCIH33cTMquLeuEV035DyDInNNOUYZaQYPzM0muHx9Jy/4AiEA\
        jC0+wSB43t55mtRS2Ai00PZqOPVFjCG0nn7rpb3Bxwo=
        """)!
    private static let attackerSHA256 = "E9:E1:B7:50:5C:29:EA:4A:EB:76:EA:8F:B7:9D:EB:F9:FC:9E:18:90:13:3B:F3:65:C1:75:55:1C:1C:4F:6A:D2"

    private let pinnedPolicy = GrowingFileConnectionPolicy(trustedLeafSHA256: [GrowingFileConnectionPolicyTests.pinnedSHA256])

    /// A trust over `chain` (leaf first) for `host`, evaluated a day into the certificates' validity
    /// and with no network fetch. `anchors` make the system trust a chain ending in one of them.
    private func trust(_ chain: [Data], host: String = "localhost", anchors: [Data] = []) throws -> SecTrust {
        let certificates = try chain.map { try XCTUnwrap(SecCertificateCreateWithData(nil, $0 as CFData)) }
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        let made = try XCTUnwrap(trust)
        if !anchors.isEmpty {
            let roots = try anchors.map { try XCTUnwrap(SecCertificateCreateWithData(nil, $0 as CFData)) }
            XCTAssertEqual(SecTrustSetAnchorCertificates(made, roots as CFArray), errSecSuccess)
            XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(made, true), errSecSuccess)
        }
        XCTAssertEqual(SecTrustSetVerifyDate(made, Date(timeIntervalSince1970: 1_791_500_000) as CFDate), errSecSuccess)  // 2026-10-08
        XCTAssertEqual(SecTrustSetNetworkFetchAllowed(made, false), errSecSuccess)
        return made
    }

    func testATrustedCertificateBehindAnotherLeafIsRejected() throws {
        // Certificates are public: a man in the middle can present the trusted one after his own
        // leaf. Only the leaf's key is proved in the handshake, so only the leaf counts.
        XCTAssertEqual(pinnedPolicy.decision(for: try trust([Self.attackerDER, Self.pinnedDER])), .reject)
        XCTAssertEqual(pinnedPolicy.decision(systemTrusted: false, leafDER: Self.attackerDER), .reject)
        XCTAssertEqual(pinnedPolicy.decision(for: try trust([Self.attackerDER])), .reject)
        XCTAssertEqual(pinnedPolicy.decision(systemTrusted: false, leafDER: nil), .reject)
    }

    func testATrustedLeafTheSystemRefusesIsAccepted() throws {
        XCTAssertFalse(SecTrustEvaluateWithError(try trust([Self.pinnedDER]), nil), "self-signed: the system refuses it")
        XCTAssertEqual(pinnedPolicy.decision(for: try trust([Self.pinnedDER])), .acceptTrustedLeaf)
        // As in Shuttle2, the trust is in the certificate for this origin: its own host name is not
        // checked again (the source asks only for the origin's challenge).
        XCTAssertEqual(pinnedPolicy.decision(for: try trust([Self.pinnedDER], host: "jellyfin.home")), .acceptTrustedLeaf)
    }

    func testAChainTheSystemTrustsGetsDefaultHandlingWhateverThePins() throws {
        let anchored = try trust([Self.attackerDER], anchors: [Self.attackerDER])
        XCTAssertTrue(SecTrustEvaluateWithError(anchored, nil), "anchored: the system trusts it")
        XCTAssertEqual(pinnedPolicy.decision(for: anchored), .systemDefault, "a pin is an exception, not a restriction")
        XCTAssertEqual(pinnedPolicy.decision(systemTrusted: true, leafDER: Self.attackerDER), .systemDefault)
        XCTAssertEqual(GrowingFileConnectionPolicy().decision(systemTrusted: true, leafDER: nil), .systemDefault)
    }

    func testNothingTrustedRejectsWhatTheSystemRefuses() throws {
        XCTAssertEqual(GrowingFileConnectionPolicy().decision(for: try trust([Self.pinnedDER])), .reject)
    }

    func testFingerprintsAreTheWholeLeafSHA256InAnyCaseAndSeparators() {
        let bare = Self.pinnedSHA256.replacingOccurrences(of: ":", with: "")
        XCTAssertEqual(GrowingFileConnectionPolicy.leafSHA256(of: Self.pinnedDER), bare)
        XCTAssertEqual(GrowingFileConnectionPolicy.leafSHA256(of: Self.attackerDER), Self.attackerSHA256.replacingOccurrences(of: ":", with: ""))

        for written in [Self.pinnedSHA256, Self.pinnedSHA256.lowercased(), bare.lowercased(), bare] {
            let policy = GrowingFileConnectionPolicy(trustedLeafSHA256: [written])
            XCTAssertEqual(policy.trustedLeafSHA256, [bare], written)
            XCTAssertEqual(policy, pinnedPolicy, written)
            XCTAssertEqual(policy.decision(systemTrusted: false, leafDER: Self.pinnedDER), .acceptTrustedLeaf, written)
        }
        var set = GrowingFileConnectionPolicy()
        set.trustedLeafSHA256 = [Self.pinnedSHA256.lowercased()]
        XCTAssertEqual(set, pinnedPolicy, "the setter normalises too")
    }
}
