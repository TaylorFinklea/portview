import Testing
@testable import PortviewProtocol

@Suite struct SmokeTests {
    @Test func bonjourServiceTypeIsStable() {
        #expect(Portview.bonjourServiceType == "_portview._udp")
    }
}
