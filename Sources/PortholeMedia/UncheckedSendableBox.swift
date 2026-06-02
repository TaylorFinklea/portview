/// Carries a non-`Sendable` value (e.g. `CVPixelBuffer`, `CMSampleBuffer`) across a
/// continuation/isolation boundary. Safe in our use: VideoToolbox hands back a freshly
/// produced buffer that we do not mutate or access concurrently.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
