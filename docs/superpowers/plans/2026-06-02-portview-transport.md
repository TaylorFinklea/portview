# PortviewTransport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build `PortviewTransport`, the QUIC transport that carries `PortviewProtocol` messages between the Mac host and iPhone client over a single encrypted connection with multiple logical lanes.

**Architecture:** A SwiftPM library depending on `PortviewProtocol`, importing Apple's `Network` framework. It wraps QUIC behind small Portview-owned types so the wire mechanics can evolve without touching the apps. Reliable QUIC streams carry the control/input/clipboard/files lanes; the **video lane uses one short-lived unidirectional QUIC stream per frame** (no cross-frame head-of-line blocking; stale frames abandoned by stream reset). The QUIC datagram flow is available (confirmed in SDK) and reserved as a future sub-frame latency optimization.

**Tech Stack:** Swift 6.2, `Network.framework` (QUIC), `Security`/`CryptoKit` for the self-signed TLS identity, Swift Testing. Depends on `PortviewProtocol`.

**Scope (M0):** establish a QUIC connection host↔client on localhost, run the `PortviewProtocol` handshake over it, and stream `VideoFrame` messages host→client. Bonjour discovery and real device pairing are **out of scope here** (M1 — the M0 client hardcodes the host address). The TLS identity in M0 is a self-signed cert generated on the host; client trust pinning is stubbed to "accept the host's presented cert and record its fingerprint" (real pin-from-QR lands in M1).

---

## Verified SDK facts (macOS 26.0 SDK, confirmed by reading the headers — do not re-derive)

- `Network.framework` ships **two** QUIC APIs: the classic `NWConnection`/`NWListener` + `NWProtocolQUIC.Options`, and the new Swift-first `NetworkConnection`/`NetworkListener` + `QUIC`/`QUICDatagram` builders.
- **This plan targets the classic `NWConnection`/`NWListener` + `NWProtocolQUIC.Options` API.** Rationale: it is stable since macOS 12 / iOS 15, fully documented, and its multiplexed-stream + datagram + TLS-identity surface is well understood. Because all QUIC usage is hidden behind Portview-owned types (below), migrating to the new `NetworkConnection` API later is a contained, app-invisible refactor. (A spike to evaluate the new API is a fine future task, not a v1 blocker.)
- QUIC datagrams ARE supported: `NWProtocolQUIC.Options.maxDatagramFrameSize`, `.isDatagram`, `.usableDatagramFrameSize`; only **one** datagram flow per connection; a datagram frame is MTU-bounded. → We do NOT use datagrams in v1 (frames exceed MTU); per-frame unidirectional streams instead.
- Multiplexed QUIC streams use `NWMultiplexGroup` + `NWConnectionGroup`; individual streams are `NWConnection(from: NWMultiplexGroup)`. **Exact stream-open/accept signatures and the `sec_identity` creation MUST be confirmed in Task 1's spike before writing dependent code** — do not prescribe these from memory.

---

### Task 1: Add target + verified QUIC loopback spike (DE-RISK FIRST)

Locks the real Network.framework QUIC API on this machine before any dependent code is written. This task's test is an integration test, not a pure unit test.

**Files:**
- Modify: `Package.swift` (add `PortviewTransport` target + test target, both depending on `PortviewProtocol`)
- Create: `Sources/PortviewTransport/TLSIdentity.swift` (self-signed identity for the listener)
- Create: `Sources/PortviewTransport/QUICParameters.swift` (builds `NWParameters` for QUIC with our ALPN + limits)
- Create: `Sources/PortviewTransport/PortviewTransport.swift` (namespace + ALPN constant)
- Test: `Tests/PortviewTransportTests/LoopbackSpikeTests.swift`

- [ ] **Step 1: Extend `Package.swift`**

Add to `products` and `targets` (keep the existing `PortviewProtocol` entries):

```swift
        .library(name: "PortviewTransport", targets: ["PortviewTransport"]),
```
```swift
        .target(name: "PortviewTransport", dependencies: ["PortviewProtocol"]),
        .testTarget(
            name: "PortviewTransportTests",
            dependencies: ["PortviewTransport", "PortviewProtocol"]
        ),
```

- [ ] **Step 2: Namespace + ALPN**

```swift
// Sources/PortviewTransport/PortviewTransport.swift
/// Transport-layer constants shared by host and client.
public enum PortviewTransport {
    /// ALPN identifier negotiated on the QUIC/TLS handshake.
    public static let alpn = "portview/1"
}
```

- [ ] **Step 3: Self-signed TLS identity (host side)**

QUIC mandates TLS 1.3 + a server identity. For M0 the host generates an ephemeral self-signed identity. **Implementer: verify the `SecIdentity` creation path against the `Security` framework before finalizing — the approach below is the intended shape; confirm the exact `SecKeyCreateRandomKey` / `SecCertificateCreateWithData` / `SecIdentityCreate` calls compile on macOS 26, and adjust as needed (this is precisely the SDK-derived detail to verify, not assume).**

```swift
// Sources/PortviewTransport/TLSIdentity.swift
import Foundation
import Security

/// A self-signed identity the host presents on the QUIC handshake.
/// In M0 this is ephemeral; M1 persists it in the keychain and exposes its
/// SPKI fingerprint for QR pairing + client pinning.
public struct TLSIdentity {
    public let secIdentity: SecIdentity

    /// Generate a fresh self-signed P-256 identity for `commonName`.
    /// NOTE: confirm the exact Security API calls compile on macOS 26 in the spike.
    public static func makeSelfSigned(commonName: String) throws -> TLSIdentity {
        // Implementer: build the self-signed cert + key here, then SecIdentity.
        // Verify against the Security framework headers in this SDK; do not guess.
        fatalError("implement against verified Security API in the spike")
    }
}
```

- [ ] **Step 4: QUIC parameters builder**

```swift
// Sources/PortviewTransport/QUICParameters.swift
import Foundation
import Network

/// Builds `NWParameters` for a Portview QUIC endpoint.
/// Implementer: confirm `NWProtocolQUIC.Options` property names against the
/// Network swiftinterface (verified to include: alpn via add-application-protocol,
/// initialMaxStreamsUnidirectional, initialMaxStreamsBidirectional, idleTimeout,
/// maxDatagramFrameSize, isDatagram, direction).
public enum QUICParameters {
    /// Server-side parameters (listener) with the host's identity.
    public static func server(identity: TLSIdentity) -> NWParameters { /* spike */ fatalError() }
    /// Client-side parameters; `pinnedFingerprint` nil in M0 (record + accept).
    public static func client(pinnedFingerprint: Data?) -> NWParameters { /* spike */ fatalError() }
}
```

- [ ] **Step 5: Write the loopback spike test**

This is the contract Task 1 must satisfy. It MUST pass before moving on.

```swift
// Tests/PortviewTransportTests/LoopbackSpikeTests.swift
import Testing
import Foundation
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct LoopbackSpikeTests {
    /// Start a QUIC listener on 127.0.0.1, connect to it, send one frame-encoded
    /// ClientHello over a reliable stream, and decode it on the listener side.
    @Test func quicLoopbackCarriesOneFramedMessage() async throws {
        // Implementer fills this in once the QUIC wiring compiles:
        //   1. host = QuicEndpoint(listening with QUICParameters.server(identity:))
        //   2. client connects via QUICParameters.client(pinnedFingerprint: nil)
        //   3. client sends Frame.encode(ClientHello(...)) on a reliable stream
        //   4. host receives bytes, FrameDecoder.push -> [.clientHello(...)]
        //   5. #expect the decoded ClientHello equals the sent one
        // Use withThrowingTaskGroup + continuations to bridge NWConnection callbacks
        // to async; bound the whole test with a timeout so a hang fails fast.
        try await Task.sleep(for: .milliseconds(1)) // placeholder until wiring lands
        #expect(Bool(true))
    }
}
```

- [ ] **Step 6: Implement the spike until the test genuinely exercises QUIC**

Replace the placeholder body with real wiring (host listener + client connection on `127.0.0.1`, one reliable stream, send/receive bridged to async). Implement `TLSIdentity.makeSelfSigned`, `QUICParameters.server/client`, and whatever minimal connection helper the test needs. Iterate `swift test` until the real handshake + byte round-trip passes.

Run: `swift test --filter LoopbackSpikeTests`
Expected: PASS — a real QUIC connection on localhost carried one framed `ClientHello`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/PortviewTransport Tests/PortviewTransportTests
git commit -m "feat(transport): verified QUIC loopback spike (TLS identity + params)"
```

---

### Task 2: MessageChannel — framing over one lane (pure, TDD)

The I/O-free layer that turns a lane's byte stream into typed messages and back. No `Network` import — fully unit-testable.

**Files:**
- Create: `Sources/PortviewTransport/MessageChannel.swift`
- Test: `Tests/PortviewTransportTests/MessageChannelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortviewTransportTests/MessageChannelTests.swift
import Testing
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct MessageChannelTests {
    @Test func encodesOutboundMessageToFrameBytes() {
        var channel = MessageChannel()
        let bytes = channel.outbound(.bye(Bye(reason: "x")))
        #expect(bytes == Frame.encodeAny(.bye(Bye(reason: "x"))))
    }

    @Test func reassemblesInboundBytesIntoMessages() throws {
        var channel = MessageChannel()
        let a = Frame.encodeAny(.bye(Bye(reason: "a")))
        let b = Frame.encodeAny(.bye(Bye(reason: "b")))
        let firstHalf = Array((a + b)[0..<(a.count - 1)])
        let rest = Array((a + b)[(a.count - 1)...])
        #expect(try channel.inbound(firstHalf).isEmpty)            // a not yet complete
        #expect(try channel.inbound(rest) == [.bye(Bye(reason: "a")), .bye(Bye(reason: "b"))])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessageChannelTests`
Expected: FAIL — `MessageChannel` undefined.

- [ ] **Step 3: Implement `MessageChannel`**

```swift
// Sources/PortviewTransport/MessageChannel.swift
import PortviewProtocol

/// Frames outbound messages and reassembles inbound bytes for a single lane.
public struct MessageChannel {
    private var decoder = FrameDecoder()
    public init() {}

    /// Encode a message to frame bytes ready to write to the lane's stream.
    public func outbound(_ message: AnyMessage) -> [UInt8] {
        Frame.encodeAny(message)
    }

    /// Feed bytes read from the lane's stream; return any complete messages.
    public mutating func inbound(_ bytes: [UInt8]) throws -> [AnyMessage] {
        try decoder.push(bytes)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessageChannelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PortviewTransport/MessageChannel.swift Tests/PortviewTransportTests/MessageChannelTests.swift
git commit -m "feat(transport): add MessageChannel (framing over a lane)"
```

---

### Task 3: PortviewConnection — lanes over QUIC + handshake-over-QUIC test

Wraps a live QUIC connection: opens/accepts the reliable lane streams, exposes `send(_:on:)` and an `AsyncStream` of inbound `(lane, AnyMessage)`, and routes video as per-frame unidirectional streams. **Build on the verified Task-1 wiring; verify all `NWMultiplexGroup`/stream APIs against the interface as you go.**

**Files:**
- Create: `Sources/PortviewTransport/PortviewConnection.swift`
- Create: `Sources/PortviewTransport/InboundMessage.swift`
- Test: `Tests/PortviewTransportTests/HandshakeOverQUICTests.swift`

- [ ] **Step 1: Define the inbound event type**

```swift
// Sources/PortviewTransport/InboundMessage.swift
import PortviewProtocol

/// A message received on a specific lane.
public struct InboundMessage: Sendable, Equatable {
    public let lane: Lane
    public let message: AnyMessage
    public init(lane: Lane, message: AnyMessage) { self.lane = lane; self.message = message }
}
```

- [ ] **Step 2: Write the integration test (the contract)**

```swift
// Tests/PortviewTransportTests/HandshakeOverQUICTests.swift
import Testing
import Foundation
@testable import PortviewTransport
@testable import PortviewProtocol

@Suite struct HandshakeOverQUICTests {
    /// Full PortviewProtocol handshake driven over a real localhost QUIC connection,
    /// then one VideoFrame delivered host->client on the video lane.
    @Test func handshakeAndFirstVideoFrameOverQUIC() async throws {
        // Implementer: stand up host + client PortviewConnection on 127.0.0.1.
        //  - client sends ClientHello on .control; host replies ServerHello; client
        //    sends StartSession; both handshakes reach .streaming.
        //  - host sends one VideoFrame on .video (its own unidirectional stream);
        //    client receives it and #expect equals what was sent.
        //  - bound with a timeout; tear both down cleanly at the end.
        try await Task.sleep(for: .milliseconds(1)) // placeholder until wiring lands
        #expect(Bool(true))
    }
}
```

- [ ] **Step 3: Implement `PortviewConnection`**

Design (implement against verified APIs; signatures below are the *intended surface*, not prescribed Network calls):

```swift
// Sources/PortviewTransport/PortviewConnection.swift
import Foundation
import Network
import PortviewProtocol

/// One live QUIC connection exposing Portview's logical lanes.
public final class PortviewConnection: @unchecked Sendable {
    /// Inbound messages across all reliable lanes, tagged with their lane.
    public var inbound: AsyncStream<InboundMessage> { /* implement */ fatalError() }

    /// Send a message on a reliable lane (control/input/clipboard/files).
    public func send(_ message: AnyMessage, on lane: Lane) async throws { /* implement */ }

    /// Send one encoded video frame on its own short-lived unidirectional stream.
    public func sendVideoFrame(_ frame: VideoFrame) async throws { /* implement */ }

    /// Close the connection and all lane streams.
    public func close() { /* implement */ }
}
```

Map each reliable lane (`control`, `input`, `clipboard`, `files`) to a long-lived bidirectional QUIC stream; keep a `MessageChannel` per lane for reassembly. Video frames each get a fresh unidirectional stream (write the framed `VideoFrame`, then close the stream). Bridge `NWConnection` receive callbacks into the `AsyncStream`.

- [ ] **Step 4: Implement until the integration test passes**

Run: `swift test --filter HandshakeOverQUICTests`
Expected: PASS — handshake completes over real QUIC and a `VideoFrame` arrives intact.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS (PortviewProtocol + PortviewTransport).

- [ ] **Step 6: Commit + update handoff**

Update `.docs/ai/current-state.md` (note transport done + how M0 video path now stands) and check off the transport item in `.docs/ai/roadmap.md`.

```bash
git add Sources/PortviewTransport Tests/PortviewTransportTests .docs/ai/current-state.md .docs/ai/roadmap.md
git commit -m "feat(transport): PortviewConnection lanes over QUIC; handshake+video e2e"
```

---

## Self-Review

**Spec coverage (§5/§7 transport):** QUIC connection ✓ (Task 1), reliable lanes via streams + video via per-frame unidirectional streams ✓ (Task 3), framing reuse via MessageChannel ✓ (Task 2), handshake-over-QUIC + first video frame ✓ (Task 3). Datagram flow explicitly deferred with rationale. Bonjour discovery + QR pairing/pinning explicitly deferred to M1.

**Placeholder scan:** the `fatalError()` bodies in Tasks 1/3 are intentional implementer slots for **SDK-derived QUIC/Security wiring that must be verified against the actual interface, not prescribed from memory** (per the repo's plan-writing rule). They are paired with concrete integration tests that define done. The pure, fully-specified code (MessageChannel, InboundMessage, namespaces) has no placeholders.

**Type consistency:** `MessageChannel.outbound/inbound`, `InboundMessage(lane:message:)`, `PortviewConnection.send(_:on:)`/`sendVideoFrame(_:)`/`inbound`/`close()`, `QUICParameters.server(identity:)`/`client(pinnedFingerprint:)`, `TLSIdentity.makeSelfSigned(commonName:)`, and `PortviewTransport.alpn` are referenced consistently. Reuses `PortviewProtocol` types (`Frame`, `FrameDecoder`, `AnyMessage`, `Lane`, `VideoFrame`, handshake messages) verbatim.

**Honest risk note:** Task 1 is deliberately a spike because the QUIC `NWMultiplexGroup` stream model and `SecIdentity` creation are the highest-uncertainty pieces. If the classic API proves awkward for per-frame unidirectional streams, evaluate the new `NetworkConnection`/`NetworkListener` + `QUIC` builder API (present in this SDK) — the Portview-owned types insulate the apps either way.
