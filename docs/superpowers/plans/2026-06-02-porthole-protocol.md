# PortholeProtocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `PortholeProtocol`, the pure-Swift wire-protocol package that both the Mac host and iPhone client depend on — binary codec primitives, the six-lane message set needed for M0, self-delimiting framing with stream reassembly, and the connection handshake state machines.

**Architecture:** A standalone SwiftPM library with no platform/OS dependencies. All wire formats are explicit, versioned binary encodings (not opaque `Codable`) so the format is stable and inspectable. Everything is deterministic and round-trip unit-tested with Swift Testing. This is the contract layer; transport I/O and capture/render live in separate packages.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing (`import Testing`). No third-party dependencies. Apache-2.0.

**Scope (M0 subset):** control-lane handshake (`ClientHello`, `ServerHello`, `StartSession`), `VideoFrame` for the video lane, and `Bye`/`ProtocolError`. Audio/clipboard/files message types are deferred to their milestones (YAGNI).

**Conventions:** Each task is one commit. Commit messages use Conventional Commits; the repo's commit tooling appends the standard `Co-Authored-By` trailer automatically. All paths are relative to the repo root `/Users/tfinklea/git/screenshare`.

---

### Task 1: Package skeleton + smoke test

**Files:**
- Create: `Package.swift`
- Create: `Sources/PortholeProtocol/Porthole.swift`
- Test: `Tests/PortholeProtocolTests/SmokeTests.swift`

- [ ] **Step 1: Create `Package.swift`**

No `platforms:` floor — this library uses zero OS APIs, so it builds and tests on the host toolchain. (The app targets pin macOS 26 / iOS 26 in their own projects later.)

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PortholeProtocol",
    products: [
        .library(name: "PortholeProtocol", targets: ["PortholeProtocol"]),
    ],
    targets: [
        .target(name: "PortholeProtocol"),
        .testTarget(
            name: "PortholeProtocolTests",
            dependencies: ["PortholeProtocol"]
        ),
    ]
)
```

- [ ] **Step 2: Create a placeholder source file so the target compiles**

```swift
// Sources/PortholeProtocol/Porthole.swift
/// Porthole wire protocol — shared contract between the Mac host and iPhone client.
/// (Named `Porthole`, not `PortholeProtocol`, to avoid a type sharing its module's name.)
public enum Porthole {
    /// Bonjour service type the host advertises and the client browses for.
    public static let bonjourServiceType = "_porthole._udp"
}
```

- [ ] **Step 3: Write the smoke test**

```swift
// Tests/PortholeProtocolTests/SmokeTests.swift
import Testing
@testable import PortholeProtocol

@Suite struct SmokeTests {
    @Test func bonjourServiceTypeIsStable() {
        #expect(Porthole.bonjourServiceType == "_porthole._udp")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: builds and PASSES (1 test).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat(protocol): scaffold PortholeProtocol package"
```

---

### Task 2: Binary codec primitives

LEB128 varints for compact lengths/counts, big-endian fixed integers, length-prefixed bytes/strings, and a 1-byte bool. The reader is bounds-checked and throws `WireError.truncated` past the end.

**Files:**
- Create: `Sources/PortholeProtocol/WireError.swift`
- Create: `Sources/PortholeProtocol/BinaryWriter.swift`
- Create: `Sources/PortholeProtocol/BinaryReader.swift`
- Test: `Tests/PortholeProtocolTests/BinaryCodecTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortholeProtocolTests/BinaryCodecTests.swift
import Testing
@testable import PortholeProtocol

@Suite struct BinaryCodecTests {
    @Test func fixedIntegersRoundTrip() throws {
        var w = BinaryWriter()
        w.putUInt8(0xAB)
        w.putUInt16(0x1234)
        w.putUInt32(0xDEADBEEF)
        w.putUInt64(0x0102030405060708)
        var r = BinaryReader(w.bytes)
        #expect(try r.uint8() == 0xAB)
        #expect(try r.uint16() == 0x1234)
        #expect(try r.uint32() == 0xDEADBEEF)
        #expect(try r.uint64() == 0x0102030405060708)
        #expect(r.isAtEnd)
    }

    @Test(arguments: [0, 1, 127, 128, 300, 16_384, UInt64.max])
    func varUIntRoundTrips(_ value: UInt64) throws {
        var w = BinaryWriter()
        w.putVarUInt(value)
        var r = BinaryReader(w.bytes)
        #expect(try r.varUInt() == value)
    }

    @Test func smallVarUIntIsOneByte() {
        var w = BinaryWriter()
        w.putVarUInt(127)
        #expect(w.bytes.count == 1)
    }

    @Test func dataAndStringRoundTrip() throws {
        var w = BinaryWriter()
        w.putData([1, 2, 3])
        w.putString("héllo 🪟")
        w.putBool(true)
        w.putBool(false)
        var r = BinaryReader(w.bytes)
        #expect(try r.data() == [1, 2, 3])
        #expect(try r.string() == "héllo 🪟")
        #expect(try r.bool() == true)
        #expect(try r.bool() == false)
    }

    @Test func readingPastEndThrows() {
        var r = BinaryReader([0x01])
        #expect(throws: WireError.truncated) {
            _ = try r.uint16()
        }
    }

    @Test func invalidBoolThrows() {
        var r = BinaryReader([0x02])
        #expect(throws: (any Error).self) {
            _ = try r.bool()
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `BinaryWriter` / `BinaryReader` / `WireError` undefined.

- [ ] **Step 3: Implement `WireError`**

```swift
// Sources/PortholeProtocol/WireError.swift
/// Errors raised while decoding the wire format.
public enum WireError: Error, Equatable, Sendable {
    /// Not enough bytes remain to decode the requested value.
    case truncated
    /// Bytes are present but structurally invalid (bad UTF-8, oversized varint, bad bool, …).
    case malformed(String)
    /// A frame referenced a message type byte we do not know.
    case unknownMessageType(UInt8)
    /// An enum field held a raw value outside its known cases.
    case unknownEnum(String, UInt64)
}
```

- [ ] **Step 4: Implement `BinaryWriter`**

```swift
// Sources/PortholeProtocol/BinaryWriter.swift
/// Appends values to a byte buffer in Porthole's wire format.
public struct BinaryWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func putUInt8(_ v: UInt8) { bytes.append(v) }

    public mutating func putUInt16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func putUInt32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }

    public mutating func putUInt64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }

    /// LEB128 unsigned varint.
    public mutating func putVarUInt(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
    }

    public mutating func putBytes(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }

    /// Length-prefixed (varint count) byte blob.
    public mutating func putData(_ raw: [UInt8]) {
        putVarUInt(UInt64(raw.count))
        bytes.append(contentsOf: raw)
    }

    public mutating func putString(_ s: String) { putData(Array(s.utf8)) }

    public mutating func putBool(_ v: Bool) { putUInt8(v ? 1 : 0) }
}
```

- [ ] **Step 5: Implement `BinaryReader`**

```swift
// Sources/PortholeProtocol/BinaryReader.swift
/// Reads values from a byte buffer in Porthole's wire format. Bounds-checked.
public struct BinaryReader: Sendable {
    private let storage: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) { self.storage = bytes }
    public init(_ slice: ArraySlice<UInt8>) { self.storage = Array(slice) }

    public var remaining: Int { storage.count - offset }
    public var isAtEnd: Bool { offset >= storage.count }

    public mutating func uint8() throws -> UInt8 {
        guard offset < storage.count else { throw WireError.truncated }
        defer { offset += 1 }
        return storage[offset]
    }

    public mutating func uint16() throws -> UInt16 {
        let hi = try uint8(), lo = try uint8()
        return (UInt16(hi) << 8) | UInt16(lo)
    }

    public mutating func uint32() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = (v << 8) | UInt32(try uint8()) }
        return v
    }

    public mutating func uint64() throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<8 { v = (v << 8) | UInt64(try uint8()) }
        return v
    }

    public mutating func varUInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try uint8()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift >= 64 { throw WireError.malformed("varint too long") }
        }
        return result
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= storage.count else { throw WireError.truncated }
        defer { offset += count }
        return Array(storage[offset..<offset + count])
    }

    public mutating func data() throws -> [UInt8] {
        let n = try varUInt()
        return try readBytes(Int(n))
    }

    public mutating func string() throws -> String {
        let raw = try data()
        guard let s = String(bytes: raw, encoding: .utf8) else {
            throw WireError.malformed("invalid utf8")
        }
        return s
    }

    public mutating func bool() throws -> Bool {
        switch try uint8() {
        case 0: return false
        case 1: return true
        case let other: throw WireError.malformed("invalid bool \(other)")
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test`
Expected: PASS (all BinaryCodec tests + smoke test).

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "feat(protocol): add binary codec primitives (varint, fixed ints, data/string/bool)"
```

---

### Task 3: Lane, Codec, and ProtocolVersion

**Files:**
- Create: `Sources/PortholeProtocol/Lane.swift`
- Create: `Sources/PortholeProtocol/Codec.swift`
- Create: `Sources/PortholeProtocol/ProtocolVersion.swift`
- Test: `Tests/PortholeProtocolTests/EnumTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortholeProtocolTests/EnumTests.swift
import Testing
@testable import PortholeProtocol

@Suite struct EnumTests {
    @Test func laneRawValuesAreStable() {
        #expect(Lane.control.rawValue == 0)
        #expect(Lane.input.rawValue == 1)
        #expect(Lane.video.rawValue == 2)
        #expect(Lane.audio.rawValue == 3)
        #expect(Lane.clipboard.rawValue == 4)
        #expect(Lane.files.rawValue == 5)
    }

    @Test func codecRawValuesAreStable() {
        #expect(Codec.h264.rawValue == 0)
        #expect(Codec.hevc.rawValue == 1)
    }

    @Test func negotiatePicksTheLowerCommonVersion() {
        #expect(ProtocolVersion.negotiate(local: 1, remote: 1) == 1)
        #expect(ProtocolVersion.negotiate(local: 3, remote: 2) == 2)
        #expect(ProtocolVersion.negotiate(local: 2, remote: 5) == 2)
    }

    @Test func negotiateRejectsVersionsBelowMinimum() {
        #expect(ProtocolVersion.negotiate(local: ProtocolVersion.current, remote: 0) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `Lane` / `Codec` / `ProtocolVersion` undefined.

- [ ] **Step 3: Implement the enums**

```swift
// Sources/PortholeProtocol/Lane.swift
/// Logical lanes carried over the single QUIC connection. Raw values are the wire encoding.
public enum Lane: UInt8, Sendable, CaseIterable {
    case control = 0
    case input = 1
    case video = 2
    case audio = 3
    case clipboard = 4
    case files = 5
}
```

```swift
// Sources/PortholeProtocol/Codec.swift
/// Video codecs the two ends can negotiate. Raw values are the wire encoding.
public enum Codec: UInt8, Sendable, CaseIterable {
    case h264 = 0
    case hevc = 1
}
```

```swift
// Sources/PortholeProtocol/ProtocolVersion.swift
/// Wire-protocol version negotiation.
public enum ProtocolVersion {
    /// Version this build speaks.
    public static let current: UInt16 = 1
    /// Oldest version this build can still interoperate with.
    public static let minimum: UInt16 = 1

    /// Returns the agreed version (the lower of the two), or `nil` if it falls below ``minimum``.
    public static func negotiate(local: UInt16, remote: UInt16) -> UInt16? {
        let agreed = Swift.min(local, remote)
        return agreed >= minimum ? agreed : nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat(protocol): add Lane, Codec, and ProtocolVersion negotiation"
```

---

### Task 4: Message model + ClientHello / ServerHello

Introduces `MessageType`, the `WireMessage` protocol every message conforms to, and the first two handshake messages. `ServerHello` carries a list of `DisplayInfo`.

**Files:**
- Create: `Sources/PortholeProtocol/MessageType.swift`
- Create: `Sources/PortholeProtocol/WireMessage.swift`
- Create: `Sources/PortholeProtocol/DisplayInfo.swift`
- Create: `Sources/PortholeProtocol/Messages/ClientHello.swift`
- Create: `Sources/PortholeProtocol/Messages/ServerHello.swift`
- Test: `Tests/PortholeProtocolTests/HelloMessageTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortholeProtocolTests/HelloMessageTests.swift
import Testing
@testable import PortholeProtocol

/// Encode a message to bytes, decode it back, and assert equality.
private func roundTrip<M: WireMessage>(_ message: M) throws -> M {
    var w = BinaryWriter()
    message.encode(into: &w)
    var r = BinaryReader(w.bytes)
    return try M(from: &r)
}

@Suite struct HelloMessageTests {
    @Test func clientHelloRoundTrips() throws {
        let m = ClientHello(
            protocolVersion: 1,
            deviceID: "DEVICE-123",
            deviceName: "Taylor's iPhone",
            codecs: [.hevc, .h264]
        )
        #expect(try roundTrip(m) == m)
        #expect(ClientHello.messageType == .clientHello)
    }

    @Test func serverHelloRoundTrips() throws {
        let m = ServerHello(
            protocolVersion: 1,
            displays: [
                DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200),
                DisplayInfo(id: 2, name: "Studio Display", width: 5120, height: 2880, scaleX100: 200),
            ],
            chosenCodec: .hevc
        )
        #expect(try roundTrip(m) == m)
        #expect(ServerHello.messageType == .serverHello)
    }

    @Test func unknownCodecByteThrows() {
        // protocolVersion=1, deviceID="", deviceName="", codecs count=1, codec raw=99
        let bytes: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x01, 99]
        var r = BinaryReader(bytes)
        #expect(throws: WireError.unknownEnum("Codec", 99)) {
            _ = try ClientHello(from: &r)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement `MessageType` and `WireMessage`**

```swift
// Sources/PortholeProtocol/MessageType.swift
/// The 1-byte tag identifying a message inside a frame. Raw values are the wire encoding.
public enum MessageType: UInt8, Sendable {
    case clientHello = 1
    case serverHello = 2
    case startSession = 3
    case videoFrame = 4
    case bye = 5
    case error = 6
}
```

```swift
// Sources/PortholeProtocol/WireMessage.swift
/// A message with a stable type tag and an explicit binary encoding.
public protocol WireMessage: Equatable, Sendable {
    static var messageType: MessageType { get }
    func encode(into writer: inout BinaryWriter)
    init(from reader: inout BinaryReader) throws
}
```

- [ ] **Step 4: Implement `DisplayInfo`**

```swift
// Sources/PortholeProtocol/DisplayInfo.swift
/// One display the host can offer to stream. `scaleX100` is points-per-pixel × 100 (e.g. 200 = 2.0×).
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var scaleX100: UInt16

    public init(id: UInt32, name: String, width: UInt32, height: UInt32, scaleX100: UInt16) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.scaleX100 = scaleX100
    }

    func encode(into w: inout BinaryWriter) {
        w.putUInt32(id)
        w.putString(name)
        w.putUInt32(width)
        w.putUInt32(height)
        w.putUInt16(scaleX100)
    }

    init(from r: inout BinaryReader) throws {
        id = try r.uint32()
        name = try r.string()
        width = try r.uint32()
        height = try r.uint32()
        scaleX100 = try r.uint16()
    }
}
```

- [ ] **Step 5: Implement `ClientHello` and `ServerHello`**

```swift
// Sources/PortholeProtocol/Messages/ClientHello.swift
/// Client → host. Opens a session and advertises supported codecs.
public struct ClientHello: WireMessage {
    public static let messageType = MessageType.clientHello
    public var protocolVersion: UInt16
    public var deviceID: String
    public var deviceName: String
    public var codecs: [Codec]

    public init(protocolVersion: UInt16, deviceID: String, deviceName: String, codecs: [Codec]) {
        self.protocolVersion = protocolVersion; self.deviceID = deviceID
        self.deviceName = deviceName; self.codecs = codecs
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt16(protocolVersion)
        w.putString(deviceID)
        w.putString(deviceName)
        w.putVarUInt(UInt64(codecs.count))
        for c in codecs { w.putUInt8(c.rawValue) }
    }

    public init(from r: inout BinaryReader) throws {
        protocolVersion = try r.uint16()
        deviceID = try r.string()
        deviceName = try r.string()
        let count = try r.varUInt()
        var result: [Codec] = []
        for _ in 0..<count {
            let raw = try r.uint8()
            guard let c = Codec(rawValue: raw) else { throw WireError.unknownEnum("Codec", UInt64(raw)) }
            result.append(c)
        }
        codecs = result
    }
}
```

```swift
// Sources/PortholeProtocol/Messages/ServerHello.swift
/// Host → client. Lists available displays and the codec chosen for this session.
public struct ServerHello: WireMessage {
    public static let messageType = MessageType.serverHello
    public var protocolVersion: UInt16
    public var displays: [DisplayInfo]
    public var chosenCodec: Codec

    public init(protocolVersion: UInt16, displays: [DisplayInfo], chosenCodec: Codec) {
        self.protocolVersion = protocolVersion; self.displays = displays; self.chosenCodec = chosenCodec
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt16(protocolVersion)
        w.putVarUInt(UInt64(displays.count))
        for d in displays { d.encode(into: &w) }
        w.putUInt8(chosenCodec.rawValue)
    }

    public init(from r: inout BinaryReader) throws {
        protocolVersion = try r.uint16()
        let count = try r.varUInt()
        var result: [DisplayInfo] = []
        for _ in 0..<count { result.append(try DisplayInfo(from: &r)) }
        displays = result
        let raw = try r.uint8()
        guard let c = Codec(rawValue: raw) else { throw WireError.unknownEnum("Codec", UInt64(raw)) }
        chosenCodec = c
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "feat(protocol): add message model, ClientHello, ServerHello, DisplayInfo"
```

---

### Task 5: StartSession, VideoFrame, Bye, ProtocolError

**Files:**
- Create: `Sources/PortholeProtocol/Messages/StartSession.swift`
- Create: `Sources/PortholeProtocol/Messages/VideoFrame.swift`
- Create: `Sources/PortholeProtocol/Messages/Bye.swift`
- Create: `Sources/PortholeProtocol/Messages/ProtocolError.swift`
- Test: `Tests/PortholeProtocolTests/SessionMessageTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortholeProtocolTests/SessionMessageTests.swift
import Testing
@testable import PortholeProtocol

private func roundTrip<M: WireMessage>(_ message: M) throws -> M {
    var w = BinaryWriter()
    message.encode(into: &w)
    var r = BinaryReader(w.bytes)
    return try M(from: &r)
}

@Suite struct SessionMessageTests {
    @Test func startSessionRoundTrips() throws {
        let m = StartSession(
            displayID: 2, codec: .hevc,
            maxWidth: 2560, maxHeight: 1440, maxFPS: 60, targetBitrate: 25_000_000
        )
        #expect(try roundTrip(m) == m)
        #expect(StartSession.messageType == .startSession)
    }

    @Test func videoFrameRoundTrips() throws {
        let m = VideoFrame(
            sequence: 42, ptsMicros: 1_000_000, isKeyframe: true,
            displayID: 2, width: 2560, height: 1440, data: [0xDE, 0xAD, 0xBE, 0xEF]
        )
        #expect(try roundTrip(m) == m)
        #expect(VideoFrame.messageType == .videoFrame)
    }

    @Test func emptyVideoFrameDataRoundTrips() throws {
        let m = VideoFrame(sequence: 0, ptsMicros: 0, isKeyframe: false,
                           displayID: 1, width: 100, height: 100, data: [])
        #expect(try roundTrip(m) == m)
    }

    @Test func byeRoundTrips() throws {
        let m = Bye(reason: "user disconnected")
        #expect(try roundTrip(m) == m)
        #expect(Bye.messageType == .bye)
    }

    @Test func protocolErrorRoundTrips() throws {
        let m = ProtocolError(code: 7, message: "no common codec")
        #expect(try roundTrip(m) == m)
        #expect(ProtocolError.messageType == .error)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement `StartSession`**

```swift
// Sources/PortholeProtocol/Messages/StartSession.swift
/// Client → host. Chosen display + desired stream parameters; host starts the video lane.
public struct StartSession: WireMessage {
    public static let messageType = MessageType.startSession
    public var displayID: UInt32
    public var codec: Codec
    public var maxWidth: UInt32
    public var maxHeight: UInt32
    public var maxFPS: UInt16
    public var targetBitrate: UInt32

    public init(displayID: UInt32, codec: Codec, maxWidth: UInt32, maxHeight: UInt32, maxFPS: UInt16, targetBitrate: UInt32) {
        self.displayID = displayID; self.codec = codec
        self.maxWidth = maxWidth; self.maxHeight = maxHeight
        self.maxFPS = maxFPS; self.targetBitrate = targetBitrate
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt32(displayID)
        w.putUInt8(codec.rawValue)
        w.putUInt32(maxWidth)
        w.putUInt32(maxHeight)
        w.putUInt16(maxFPS)
        w.putUInt32(targetBitrate)
    }

    public init(from r: inout BinaryReader) throws {
        displayID = try r.uint32()
        let raw = try r.uint8()
        guard let c = Codec(rawValue: raw) else { throw WireError.unknownEnum("Codec", UInt64(raw)) }
        codec = c
        maxWidth = try r.uint32()
        maxHeight = try r.uint32()
        maxFPS = try r.uint16()
        targetBitrate = try r.uint32()
    }
}
```

- [ ] **Step 4: Implement `VideoFrame`**

```swift
// Sources/PortholeProtocol/Messages/VideoFrame.swift
/// Host → client (video lane). One encoded access unit plus its metadata.
public struct VideoFrame: WireMessage {
    public static let messageType = MessageType.videoFrame
    public var sequence: UInt64
    public var ptsMicros: UInt64
    public var isKeyframe: Bool
    public var displayID: UInt32
    public var width: UInt32
    public var height: UInt32
    public var data: [UInt8]

    public init(sequence: UInt64, ptsMicros: UInt64, isKeyframe: Bool, displayID: UInt32, width: UInt32, height: UInt32, data: [UInt8]) {
        self.sequence = sequence; self.ptsMicros = ptsMicros; self.isKeyframe = isKeyframe
        self.displayID = displayID; self.width = width; self.height = height; self.data = data
    }

    public func encode(into w: inout BinaryWriter) {
        w.putUInt64(sequence)
        w.putUInt64(ptsMicros)
        w.putBool(isKeyframe)
        w.putUInt32(displayID)
        w.putUInt32(width)
        w.putUInt32(height)
        w.putData(data)
    }

    public init(from r: inout BinaryReader) throws {
        sequence = try r.uint64()
        ptsMicros = try r.uint64()
        isKeyframe = try r.bool()
        displayID = try r.uint32()
        width = try r.uint32()
        height = try r.uint32()
        data = try r.data()
    }
}
```

- [ ] **Step 5: Implement `Bye` and `ProtocolError`**

```swift
// Sources/PortholeProtocol/Messages/Bye.swift
/// Either side. Graceful session close with a human-readable reason.
public struct Bye: WireMessage {
    public static let messageType = MessageType.bye
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public func encode(into w: inout BinaryWriter) { w.putString(reason) }
    public init(from r: inout BinaryReader) throws { reason = try r.string() }
}
```

```swift
// Sources/PortholeProtocol/Messages/ProtocolError.swift
/// Either side. A coded error; closes the session.
public struct ProtocolError: WireMessage {
    public static let messageType = MessageType.error
    public var code: UInt16
    public var message: String
    public init(code: UInt16, message: String) { self.code = code; self.message = message }
    public func encode(into w: inout BinaryWriter) { w.putUInt16(code); w.putString(message) }
    public init(from r: inout BinaryReader) throws { code = try r.uint16(); message = try r.string() }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "feat(protocol): add StartSession, VideoFrame, Bye, ProtocolError messages"
```

---

### Task 6: AnyMessage + single-message framing

A frame is self-delimiting: `[varint bodyLength][uint8 messageType][payload]`, where `bodyLength` counts the type byte plus payload. `AnyMessage` is the decoded sum type.

**Files:**
- Create: `Sources/PortholeProtocol/AnyMessage.swift`
- Create: `Sources/PortholeProtocol/Frame.swift`
- Test: `Tests/PortholeProtocolTests/FrameTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortholeProtocolTests/FrameTests.swift
import Testing
@testable import PortholeProtocol

@Suite struct FrameTests {
    @Test func encodeThenDecodeYieldsSameMessage() throws {
        let hello = ClientHello(protocolVersion: 1, deviceID: "D", deviceName: "N", codecs: [.hevc])
        let frame = Frame.encode(hello)
        let decoded = try Frame.decode(frame)
        #expect(decoded == .clientHello(hello))
    }

    @Test func frameBodyLengthCountsTypeBytePlusPayload() throws {
        let bye = Bye(reason: "x")            // payload: putString("x") => varint 1 + 1 byte = 2 bytes
        let frame = Frame.encode(bye)
        // frame = [bodyLen varint][type][payload]; bodyLen = 1 (type) + 2 (payload) = 3
        #expect(frame.first == 3)
        var r = BinaryReader(frame)
        #expect(try r.varUInt() == 3)
    }

    @Test func decodingUnknownTypeThrows() {
        // bodyLen=1, type=99 (unknown), no payload
        let bytes: [UInt8] = [0x01, 99]
        #expect(throws: WireError.unknownMessageType(99)) {
            _ = try Frame.decode(bytes)
        }
    }

    @Test func anyMessageReportsItsType() {
        #expect(AnyMessage.bye(Bye(reason: "")).messageType == .bye)
        #expect(AnyMessage.videoFrame(VideoFrame(sequence: 0, ptsMicros: 0, isKeyframe: false, displayID: 0, width: 0, height: 0, data: [])).messageType == .videoFrame)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `Frame` / `AnyMessage` undefined.

- [ ] **Step 3: Implement `AnyMessage`**

```swift
// Sources/PortholeProtocol/AnyMessage.swift
/// A decoded message of any known type.
public enum AnyMessage: Equatable, Sendable {
    case clientHello(ClientHello)
    case serverHello(ServerHello)
    case startSession(StartSession)
    case videoFrame(VideoFrame)
    case bye(Bye)
    case error(ProtocolError)

    public var messageType: MessageType {
        switch self {
        case .clientHello: .clientHello
        case .serverHello: .serverHello
        case .startSession: .startSession
        case .videoFrame: .videoFrame
        case .bye: .bye
        case .error: .error
        }
    }
}
```

- [ ] **Step 4: Implement `Frame`**

```swift
// Sources/PortholeProtocol/Frame.swift
/// Self-delimiting framing: `[varint bodyLength][uint8 messageType][payload]`.
/// `bodyLength` counts the type byte plus the payload.
public enum Frame {
    /// Encode a single message into one frame.
    public static func encode<M: WireMessage>(_ message: M) -> [UInt8] {
        var payload = BinaryWriter()
        message.encode(into: &payload)

        var out = BinaryWriter()
        out.putVarUInt(UInt64(payload.bytes.count + 1)) // +1 for the type byte
        out.putUInt8(M.messageType.rawValue)
        out.putBytes(payload.bytes)
        return out.bytes
    }

    /// Encode whichever concrete message an `AnyMessage` holds.
    public static func encodeAny(_ message: AnyMessage) -> [UInt8] {
        switch message {
        case .clientHello(let m): encode(m)
        case .serverHello(let m): encode(m)
        case .startSession(let m): encode(m)
        case .videoFrame(let m): encode(m)
        case .bye(let m): encode(m)
        case .error(let m): encode(m)
        }
    }

    /// Decode exactly one frame from `bytes` (which must contain a complete frame).
    public static func decode(_ bytes: [UInt8]) throws -> AnyMessage {
        var r = BinaryReader(bytes)
        let bodyLength = try r.varUInt()
        let body = try r.readBytes(Int(bodyLength))
        return try decodeBody(body)
    }

    /// Decode a frame body (`[uint8 messageType][payload]`) into a message.
    static func decodeBody(_ body: [UInt8]) throws -> AnyMessage {
        var r = BinaryReader(body)
        let typeRaw = try r.uint8()
        guard let type = MessageType(rawValue: typeRaw) else {
            throw WireError.unknownMessageType(typeRaw)
        }
        switch type {
        case .clientHello: return .clientHello(try ClientHello(from: &r))
        case .serverHello: return .serverHello(try ServerHello(from: &r))
        case .startSession: return .startSession(try StartSession(from: &r))
        case .videoFrame: return .videoFrame(try VideoFrame(from: &r))
        case .bye: return .bye(try Bye(from: &r))
        case .error: return .error(try ProtocolError(from: &r))
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat(protocol): add AnyMessage and self-delimiting frame codec"
```

---

### Task 7: Streaming frame reassembly

`FrameDecoder` buffers a byte stream and emits complete messages as they arrive, holding partial frames until the rest shows up. Essential because QUIC/stream reads deliver arbitrary byte chunks.

**Files:**
- Create: `Sources/PortholeProtocol/FrameDecoder.swift`
- Test: `Tests/PortholeProtocolTests/FrameDecoderTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortholeProtocolTests/FrameDecoderTests.swift
import Testing
@testable import PortholeProtocol

@Suite struct FrameDecoderTests {
    @Test func decodesTwoMessagesFromOneChunk() throws {
        let a = Bye(reason: "first")
        let b = Bye(reason: "second")
        var stream = Frame.encode(a)
        stream.append(contentsOf: Frame.encode(b))

        var decoder = FrameDecoder()
        let messages = try decoder.push(stream)
        #expect(messages == [.bye(a), .bye(b)])
    }

    @Test func buffersPartialFrameUntilComplete() throws {
        let m = ClientHello(protocolVersion: 1, deviceID: "DEVICE", deviceName: "Phone", codecs: [.hevc, .h264])
        let frame = Frame.encode(m)
        let split = frame.count / 2

        var decoder = FrameDecoder()
        #expect(try decoder.push(Array(frame[0..<split])).isEmpty)   // not enough yet
        let messages = try decoder.push(Array(frame[split...]))      // now complete
        #expect(messages == [.clientHello(m)])
    }

    @Test func handlesByteAtATimeDelivery() throws {
        let m = Bye(reason: "trickle")
        let frame = Frame.encode(m)
        var decoder = FrameDecoder()
        var collected: [AnyMessage] = []
        for byte in frame {
            collected.append(contentsOf: try decoder.push([byte]))
        }
        #expect(collected == [.bye(m)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `FrameDecoder` undefined.

- [ ] **Step 3: Implement `FrameDecoder`**

```swift
// Sources/PortholeProtocol/FrameDecoder.swift
/// Accumulates a byte stream and yields complete messages as frames arrive.
public struct FrameDecoder {
    private var buffer: [UInt8] = []
    public init() {}

    /// Append `incoming` bytes; return every message that is now fully available.
    public mutating func push(_ incoming: [UInt8]) throws -> [AnyMessage] {
        buffer.append(contentsOf: incoming)
        var messages: [AnyMessage] = []

        while true {
            var reader = BinaryReader(buffer)
            let bodyLength: UInt64
            do {
                bodyLength = try reader.varUInt()
            } catch WireError.truncated {
                break // length prefix not fully arrived yet
            }
            let headerSize = reader.offset
            guard buffer.count - headerSize >= Int(bodyLength) else {
                break // body not fully arrived yet
            }
            let body = Array(buffer[headerSize..<headerSize + Int(bodyLength)])
            messages.append(try Frame.decodeBody(body))
            buffer.removeFirst(headerSize + Int(bodyLength))
        }
        return messages
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat(protocol): add streaming FrameDecoder reassembly"
```

---

### Task 8: Handshake state machines

Pure, I/O-free state machines that drive the control-lane handshake and reject out-of-order messages. The transport layer will own the actual sending/receiving and call into these.

**Files:**
- Create: `Sources/PortholeProtocol/HandshakeError.swift`
- Create: `Sources/PortholeProtocol/ClientHandshake.swift`
- Create: `Sources/PortholeProtocol/ServerHandshake.swift`
- Test: `Tests/PortholeProtocolTests/HandshakeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PortholeProtocolTests/HandshakeTests.swift
import Testing
@testable import PortholeProtocol

@Suite struct HandshakeTests {
    @Test func happyPathDrivesBothSidesToStreaming() throws {
        var client = ClientHandshake(deviceID: "D", deviceName: "Phone", supportedCodecs: [.hevc, .h264])
        var server = ServerHandshake(
            displays: [DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200)],
            supportedCodecs: [.hevc]
        )

        let hello = client.start()
        #expect(client.state == .awaitingServerHello)

        let serverHello = try server.handle(hello)
        #expect(server.state == .awaitingStartSession)
        #expect(serverHello.chosenCodec == .hevc)

        let start = try client.handle(serverHello, displayID: 1, maxWidth: 3456, maxHeight: 2234, maxFPS: 60, targetBitrate: 25_000_000)
        #expect(client.state == .ready)

        try server.handle(start)
        #expect(server.state == .streaming)

        client.didStartStreaming()
        #expect(client.state == .streaming)
    }

    @Test func serverRejectsHelloWithNoCommonCodec() {
        var server = ServerHandshake(displays: [], supportedCodecs: [.hevc])
        let hello = ClientHello(protocolVersion: 1, deviceID: "D", deviceName: "P", codecs: [.h264])
        #expect(throws: HandshakeError.noCommonCodec) {
            _ = try server.handle(hello)
        }
    }

    @Test func clientRejectsServerHelloBeforeStarting() {
        var client = ClientHandshake(deviceID: "D", deviceName: "P", supportedCodecs: [.hevc])
        let serverHello = ServerHello(protocolVersion: 1, displays: [], chosenCodec: .hevc)
        #expect(throws: HandshakeError.unexpectedMessage) {
            _ = try client.handle(serverHello, displayID: 0, maxWidth: 0, maxHeight: 0, maxFPS: 0, targetBitrate: 0)
        }
    }

    @Test func serverRejectsVersionBelowMinimum() {
        var server = ServerHandshake(displays: [], supportedCodecs: [.hevc])
        let hello = ClientHello(protocolVersion: 0, deviceID: "D", deviceName: "P", codecs: [.hevc])
        #expect(throws: HandshakeError.versionMismatch) {
            _ = try server.handle(hello)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — handshake types undefined.

- [ ] **Step 3: Implement `HandshakeError`**

```swift
// Sources/PortholeProtocol/HandshakeError.swift
/// Errors from the handshake state machines.
public enum HandshakeError: Error, Equatable, Sendable {
    case unexpectedMessage
    case versionMismatch
    case noCommonCodec
}
```

- [ ] **Step 4: Implement `ClientHandshake`**

```swift
// Sources/PortholeProtocol/ClientHandshake.swift
/// Drives the client side of the control-lane handshake. I/O-free.
public struct ClientHandshake {
    public enum State: Equatable, Sendable {
        case idle, awaitingServerHello, ready, streaming, closed
    }
    public private(set) var state: State = .idle

    public let deviceID: String
    public let deviceName: String
    public let supportedCodecs: [Codec]

    public init(deviceID: String, deviceName: String, supportedCodecs: [Codec]) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.supportedCodecs = supportedCodecs
    }

    /// Produce the opening `ClientHello`.
    public mutating func start() -> ClientHello {
        state = .awaitingServerHello
        return ClientHello(protocolVersion: ProtocolVersion.current,
                           deviceID: deviceID, deviceName: deviceName, codecs: supportedCodecs)
    }

    /// Validate the `ServerHello` and produce the `StartSession` to send.
    public mutating func handle(_ hello: ServerHello, displayID: UInt32, maxWidth: UInt32, maxHeight: UInt32, maxFPS: UInt16, targetBitrate: UInt32) throws -> StartSession {
        guard state == .awaitingServerHello else { throw HandshakeError.unexpectedMessage }
        guard ProtocolVersion.negotiate(local: ProtocolVersion.current, remote: hello.protocolVersion) != nil else {
            throw HandshakeError.versionMismatch
        }
        guard supportedCodecs.contains(hello.chosenCodec) else { throw HandshakeError.noCommonCodec }
        state = .ready
        return StartSession(displayID: displayID, codec: hello.chosenCodec,
                            maxWidth: maxWidth, maxHeight: maxHeight, maxFPS: maxFPS, targetBitrate: targetBitrate)
    }

    /// Call once the host's first video frame is flowing.
    public mutating func didStartStreaming() {
        if state == .ready { state = .streaming }
    }
}
```

- [ ] **Step 5: Implement `ServerHandshake`**

```swift
// Sources/PortholeProtocol/ServerHandshake.swift
/// Drives the host side of the control-lane handshake. I/O-free.
public struct ServerHandshake {
    public enum State: Equatable, Sendable {
        case idle, awaitingStartSession, streaming, closed
    }
    public private(set) var state: State = .idle

    public let displays: [DisplayInfo]
    public let supportedCodecs: [Codec]

    public init(displays: [DisplayInfo], supportedCodecs: [Codec]) {
        self.displays = displays; self.supportedCodecs = supportedCodecs
    }

    /// Validate the `ClientHello`, pick a codec, and produce the `ServerHello`.
    public mutating func handle(_ hello: ClientHello) throws -> ServerHello {
        guard state == .idle else { throw HandshakeError.unexpectedMessage }
        guard ProtocolVersion.negotiate(local: ProtocolVersion.current, remote: hello.protocolVersion) != nil else {
            throw HandshakeError.versionMismatch
        }
        guard let codec = supportedCodecs.first(where: { hello.codecs.contains($0) }) else {
            throw HandshakeError.noCommonCodec
        }
        state = .awaitingStartSession
        return ServerHello(protocolVersion: ProtocolVersion.current, displays: displays, chosenCodec: codec)
    }

    /// Accept the client's `StartSession` and move to streaming.
    public mutating func handle(_ start: StartSession) throws {
        guard state == .awaitingStartSession else { throw HandshakeError.unexpectedMessage }
        state = .streaming
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "feat(protocol): add client/server handshake state machines"
```

---

### Task 9: End-to-end handshake over frames + handoff doc update

Proves the whole package composes: run the handshake while serializing every message through the frame codec + `FrameDecoder`, exactly as the transport layer will.

**Files:**
- Test: `Tests/PortholeProtocolTests/EndToEndHandshakeTests.swift`
- Modify: `.docs/ai/current-state.md`

- [ ] **Step 1: Write the integration test**

```swift
// Tests/PortholeProtocolTests/EndToEndHandshakeTests.swift
import Testing
@testable import PortholeProtocol

@Suite struct EndToEndHandshakeTests {
    /// Serialize a message to a frame, push it through a decoder, and return the single decoded message.
    private func ship<M: WireMessage>(_ message: M, into decoder: inout FrameDecoder) throws -> AnyMessage {
        let out = try decoder.push(Frame.encode(message))
        #expect(out.count == 1)
        return out[0]
    }

    @Test func fullHandshakeSurvivesFrameRoundTrips() throws {
        var client = ClientHandshake(deviceID: "PHONE-1", deviceName: "iPhone", supportedCodecs: [.hevc, .h264])
        var server = ServerHandshake(
            displays: [DisplayInfo(id: 1, name: "Built-in", width: 3456, height: 2234, scaleX100: 200)],
            supportedCodecs: [.hevc]
        )
        var toServer = FrameDecoder()
        var toClient = FrameDecoder()

        // client → server: ClientHello
        guard case let .clientHello(hello) = try ship(client.start(), into: &toServer) else {
            Issue.record("expected ClientHello"); return
        }
        // server → client: ServerHello
        guard case let .serverHello(serverHello) = try ship(try server.handle(hello), into: &toClient) else {
            Issue.record("expected ServerHello"); return
        }
        // client → server: StartSession
        let start = try client.handle(serverHello, displayID: 1, maxWidth: 3456, maxHeight: 2234, maxFPS: 60, targetBitrate: 25_000_000)
        guard case let .startSession(decodedStart) = try ship(start, into: &toServer) else {
            Issue.record("expected StartSession"); return
        }
        try server.handle(decodedStart)
        client.didStartStreaming()

        #expect(server.state == .streaming)
        #expect(client.state == .streaming)
        #expect(serverHello.chosenCodec == .hevc)
        #expect(decodedStart.displayID == 1)
    }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test`
Expected: PASS (full suite green).

- [ ] **Step 3: Update the handoff breadcrumb**

In `.docs/ai/current-state.md`, replace the **Build Status** section body with:

```markdown
- Toolchain: Swift 6.2, Xcode 26.0.1, macOS 26.3.1 (Apple Silicon). Confirmed.
- `PortholeProtocol` package: builds clean, `swift test` all green. Wire protocol (primitives, 6 messages, framing, FrameDecoder, handshake state machines) complete.
- Next: `PortholeTransport` (QUIC over Network.framework) — its own plan.
```

And in `.docs/ai/roadmap.md`, check off the first M0 item (`PortholeProtocol`).

- [ ] **Step 4: Commit**

```bash
git add Tests .docs/ai/current-state.md .docs/ai/roadmap.md
git commit -m "test(protocol): end-to-end handshake over frames; update handoff state"
```

---

## Self-Review

**Spec coverage (§5 Wire protocol):** lanes ✓ (Task 3), message framing `[varint length][type][payload]` ✓ (Task 6), protocol version negotiation ✓ (Task 3), handshake messages ClientHello/ServerHello/StartSession ✓ (Tasks 4–5), VideoFrame for the video lane ✓ (Task 5), Bye/Error ✓ (Task 5), handshake sequence as a state machine ✓ (Task 8), stream reassembly for real transport reads ✓ (Task 7), end-to-end composition ✓ (Task 9). Deferred by design (YAGNI, later milestones): audio/clipboard/files message bodies, pairing payload encoding — these belong to their feature plans, not the M0 contract.

**Placeholder scan:** none — every step has complete code, exact paths, exact commands, expected output.

**Type consistency:** `BinaryWriter.bytes`, `BinaryReader.readBytes(_:)`/`data()`/`string()`, `WireMessage` requirements (`messageType`, `encode(into:)`, `init(from:)`), `Frame.encode`/`decode`/`decodeBody`, `FrameDecoder.push`, and handshake method signatures are referenced identically across tasks. `ProtocolError` (not `Error`) avoids clashing with Swift's `Error`. `scaleX100` used consistently in `DisplayInfo`.

**Out-of-scope confirmation:** this plan deliberately stops at the I/O-free contract; QUIC transport and capture/render are separate plans, each independently testable, as noted in the header.
