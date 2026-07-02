/// A decoded message of any known type.
public enum AnyMessage: Equatable, Sendable {
    case clientHello(ClientHello)
    case serverHello(ServerHello)
    case startSession(StartSession)
    case videoFrame(VideoFrame)
    case bye(Bye)
    case error(ProtocolError)
    case pointerMove(PointerMove)
    case pointerButton(PointerButton)
    case scroll(Scroll)
    case typeText(TypeText)
    case keyEvent(KeyEvent)
    case cursorPosition(CursorPosition)
    case clipboardUpdate(ClipboardUpdate)
    case switchDisplay(SwitchDisplay)
    case fileOffer(FileOffer)
    case fileChunk(FileChunk)
    case audioFrame(AudioFrame)
    case viewport(Viewport)
    case qualityStats(QualityStats)
    case sasClientCommit(SASClientCommit)
    case sasHostCommit(SASHostCommit)
    case sasClientReveal(SASClientReveal)
    case sasHostReveal(SASHostReveal)
    case sasClientConfirm(SASClientConfirm)
    case displaysUpdate(DisplaysUpdate)
    case hostLockStatus(HostLockStatus)
    case ping(Ping)
    case pong(Pong)
    case clientFeedback(ClientFeedback)
    case requestKeyframe(RequestKeyframe)

    public var messageType: MessageType {
        switch self {
        case .clientHello: .clientHello
        case .serverHello: .serverHello
        case .startSession: .startSession
        case .videoFrame: .videoFrame
        case .bye: .bye
        case .error: .error
        case .pointerMove: .pointerMove
        case .pointerButton: .pointerButton
        case .scroll: .scroll
        case .typeText: .typeText
        case .keyEvent: .keyEvent
        case .cursorPosition: .cursorPosition
        case .clipboardUpdate: .clipboardUpdate
        case .switchDisplay: .switchDisplay
        case .fileOffer: .fileOffer
        case .fileChunk: .fileChunk
        case .audioFrame: .audioFrame
        case .viewport: .viewport
        case .qualityStats: .qualityStats
        case .sasClientCommit: .sasClientCommit
        case .sasHostCommit: .sasHostCommit
        case .sasClientReveal: .sasClientReveal
        case .sasHostReveal: .sasHostReveal
        case .sasClientConfirm: .sasClientConfirm
        case .displaysUpdate: .displaysUpdate
        case .hostLockStatus: .hostLockStatus
        case .ping: .ping
        case .pong: .pong
        case .clientFeedback: .clientFeedback
        case .requestKeyframe: .requestKeyframe
        }
    }
}
