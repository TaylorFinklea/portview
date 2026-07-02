import XCTest
import AVFoundation

@testable import PortviewClient

/// AVAudioSession interruption handling: a call/Siri/alarm deactivates the session and stops the
/// engine, so the player must pause on `.began` and restart on `.ended` + `.shouldResume` — without
/// this, audio silently dies mid-stream. Notifications are posted synthetically (the block observer
/// on the main queue delivers synchronously when posted from the main thread); the engine itself
/// can't run meaningfully in the simulator, so the assertions target the observable state
/// transitions, not real audio. Device-verify with a real phone call is a human follow-up.
@MainActor
final class AudioPlayerInterruptionTests: XCTestCase {
    private func post(type: AVAudioSession.InterruptionType,
                      options: AVAudioSession.InterruptionOptions = []) {
        var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if !options.isEmpty {
            userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
        }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: userInfo)
    }

    func testInterruptionBeganPausesPlayback() {
        let audioPlayer = AudioPlayer()
        post(type: .began)
        XCTAssertTrue(audioPlayer.isInterrupted)
        XCTAssertEqual(audioPlayer.interruptionResumeAttempts, 0)
    }

    func testInterruptionEndedWithShouldResumeRestartsEngine() {
        let audioPlayer = AudioPlayer()
        post(type: .began)
        post(type: .ended, options: .shouldResume)
        XCTAssertFalse(audioPlayer.isInterrupted)
        XCTAssertEqual(audioPlayer.interruptionResumeAttempts, 1)
    }

    func testInterruptionEndedWithoutResumeClearsStateButDoesNotRestart() {
        let audioPlayer = AudioPlayer()
        post(type: .began)
        post(type: .ended)
        XCTAssertFalse(audioPlayer.isInterrupted)
        XCTAssertEqual(audioPlayer.interruptionResumeAttempts, 0)
    }

    /// A stray `.ended` with no preceding `.began` (e.g. delivered to a fresh player) is a no-op.
    func testSpuriousEndedIsIgnored() {
        let audioPlayer = AudioPlayer()
        post(type: .ended, options: .shouldResume)
        XCTAssertFalse(audioPlayer.isInterrupted)
        XCTAssertEqual(audioPlayer.interruptionResumeAttempts, 0)
    }

    /// `stop()` (session teardown) clears a pending interruption so the next session starts fresh.
    func testStopClearsInterruptedState() {
        let audioPlayer = AudioPlayer()
        post(type: .began)
        audioPlayer.stop()
        XCTAssertFalse(audioPlayer.isInterrupted)
    }
}
