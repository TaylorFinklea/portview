import Testing
@testable import PortviewProtocol

@Suite struct ClientFeedbackTests {
    @Test func clientFeedbackRoundTrips() throws {
        let message = ClientFeedback(
            receivedFPSX100: 5_985,
            receivedMbpsX100: 4_275,
            averageDecodeMsX100: 250,
            decodeQueueDepth: 3,
            droppedFrames: 7,
            rttMicros: 15_000
        )

        var writer = BinaryWriter()
        message.encode(into: &writer)
        var reader = BinaryReader(writer.bytes)

        let decoded = try ClientFeedback(from: &reader)
        #expect(decoded == message)
        #expect(decoded.receivedFPSX100 == 5_985)
        #expect(decoded.receivedMbpsX100 == 4_275)
        #expect(decoded.averageDecodeMsX100 == 250)
        #expect(decoded.decodeQueueDepth == 3)
        #expect(decoded.droppedFrames == 7)
        #expect(decoded.rttMicros == 15_000)
        #expect(ClientFeedback.messageType == .clientFeedback)
    }

    @Test func clientFeedbackThroughFrame() throws {
        let message = ClientFeedback(
            receivedFPSX100: 6_000,
            receivedMbpsX100: 1_234,
            averageDecodeMsX100: 89,
            decodeQueueDepth: 0,
            droppedFrames: 0,
            rttMicros: 8_500
        )

        #expect(try Frame.decode(Frame.encode(message)) == .clientFeedback(message))
    }

    @Test func clientFeedbackScaledAccessors() {
        let message = ClientFeedback(
            receivedFPSX100: 5_985,
            receivedMbpsX100: 4_275,
            averageDecodeMsX100: 250,
            decodeQueueDepth: 0,
            droppedFrames: 0,
            rttMicros: 0
        )
        #expect(message.receivedFPS == 59.85)
        #expect(message.receivedMbps == 42.75)
        #expect(message.averageDecodeMs == 2.5)
    }
}
