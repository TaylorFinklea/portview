import Testing
@testable import PortholeProtocol

@Suite struct SmokeTests {
    @Test func bonjourServiceTypeIsStable() {
        #expect(Porthole.bonjourServiceType == "_porthole._udp")
    }
}
