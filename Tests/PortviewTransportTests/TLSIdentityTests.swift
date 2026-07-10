// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Security
@testable import PortviewTransport

@Suite struct TLSIdentityTests {
    @Test func generatesEphemeralSelfSignedIdentity() throws {
        let identity = try TLSIdentity.makeEphemeralSelfSigned(commonName: "Portview-Test")

        // The identity must yield a certificate...
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity.secIdentity, &cert)
        #expect(status == errSecSuccess)
        #expect(cert != nil)

        // ...and bridge to a Network-framework sec_identity_t for QUIC/TLS.
        _ = try identity.makeSecIdentityT()
    }
}
