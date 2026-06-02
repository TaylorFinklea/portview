import Testing
@testable import PortviewProtocol

@Suite struct FileTransferTests {
    @Test func fileOfferRoundTrips() throws {
        let message = FileOffer(transferID: 42, name: "report.pdf", size: 1_000_000)
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try FileOffer(from: &r) == message)
        #expect(FileOffer.messageType == .fileOffer)
    }

    @Test func fileChunkRoundTrips() throws {
        let message = FileChunk(transferID: 42, isLast: true, data: [0, 1, 2, 250, 255])
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try FileChunk(from: &r) == message)
    }

    @Test func emptyLastChunkRoundTrips() throws {
        let message = FileChunk(transferID: 1, isLast: true, data: [])
        var w = BinaryWriter()
        message.encode(into: &w)
        var r = BinaryReader(w.bytes)
        #expect(try FileChunk(from: &r) == message)
    }

    @Test func fileMessagesThroughFrame() throws {
        let offer: AnyMessage = .fileOffer(FileOffer(transferID: 7, name: "a.txt", size: 3))
        let chunk: AnyMessage = .fileChunk(FileChunk(transferID: 7, isLast: false, data: [9, 9, 9]))
        #expect(try Frame.decode(Frame.encodeAny(offer)) == offer)
        #expect(try Frame.decode(Frame.encodeAny(chunk)) == chunk)
    }
}
