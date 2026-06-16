import Testing
@testable import PortviewHostCore

/// Pure derivation of the host's guided permission onboarding from the two real grant bools.
/// Screen Recording is the gate (and needs a relaunch to take effect); Accessibility follows.
@Suite struct PermissionsOnboardingTests {
    @Test func nothingGrantedGatesOnScreenRecording() {
        let o = PermissionsOnboarding(screenRecordingGranted: false, accessibilityGranted: false)
        #expect(o.step == .screenRecording)
        #expect(o.allGranted == false)
        #expect(o.requiresRelaunch == true)
        #expect(o.primaryPane == .screenRecording)
    }

    @Test func screenRecordingIsTheGateEvenIfAccessibilityGranted() {
        let o = PermissionsOnboarding(screenRecordingGranted: false, accessibilityGranted: true)
        #expect(o.step == .screenRecording)
        #expect(o.requiresRelaunch == true)
    }

    @Test func accessibilityStepWhenOnlyAccessibilityMissing() {
        let o = PermissionsOnboarding(screenRecordingGranted: true, accessibilityGranted: false)
        #expect(o.step == .accessibility)
        #expect(o.requiresRelaunch == false) // accessibility takes effect live, no relaunch
        #expect(o.primaryPane == .accessibility)
    }

    @Test func bothGrantedIsComplete() {
        let o = PermissionsOnboarding(screenRecordingGranted: true, accessibilityGranted: true)
        #expect(o.step == .complete)
        #expect(o.allGranted == true)
        #expect(o.primaryPane == nil)
        #expect(o.requiresRelaunch == false)
        #expect(o.title.isEmpty)
    }
}
