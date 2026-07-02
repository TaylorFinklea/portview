/// The 1-byte tag identifying a message inside a frame. Raw values are the wire encoding.
///
/// Reserved tag ranges for future additions (lead-assigned; do not self-allocate):
/// - 1-99: core/stable message types (lead-assigned)
/// - 100-149: client -> host input/feedback
/// - 150-199: host -> client telemetry
/// - 200-254: experimental
/// - 255: reserved
public enum MessageType: UInt8, Sendable, CaseIterable {
    case clientHello = 1
    case serverHello = 2
    case startSession = 3
    case videoFrame = 4
    case bye = 5
    case error = 6
    case pointerMove = 7
    case pointerButton = 8
    case scroll = 9
    case typeText = 10
    case keyEvent = 11
    case cursorPosition = 12
    case clipboardUpdate = 13
    case switchDisplay = 14
    case fileOffer = 15
    case fileChunk = 16
    case audioFrame = 17
    case viewport = 18
    case qualityStats = 19
    case sasClientCommit = 20
    case sasHostCommit = 21
    case sasClientReveal = 22
    case sasHostReveal = 23
    case sasClientConfirm = 24
    case displaysUpdate = 25
    case hostLockStatus = 26
}
