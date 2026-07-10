// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Network
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct DecodeErrorSurfacingTests {
    /// A malformed KNOWN-tag frame (a `.bye` body whose string-length prefix claims more bytes
    /// than are present) must finish the inbound stream instead of silently stalling forever.
    /// Drives `PortviewConnection.processIncoming` directly — a testable seam — rather than a
    /// live socket, since only the decode path under test matters here.
    @Test func malformedKnownTagBodyFinishesInboundStreamInsteadOfStalling() async throws {
        let dummy = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let connection = PortviewConnection(connection: dummy, queue: DispatchQueue(label: "test.decode-error"))

        var writer = BinaryWriter()
        let body: [UInt8] = [MessageType.bye.rawValue, 10] // claims a 10-byte string with none present
        writer.putVarUInt(UInt64(body.count))
        writer.putBytes(body)

        let didDecode = connection.processIncoming(writer.bytes)
        #expect(didDecode == false)

        let terminated = try await withTimeout(.seconds(5)) {
            for await _ in connection.inbound {}
            return true
        }
        #expect(terminated)
    }
}
