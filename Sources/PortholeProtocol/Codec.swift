/// Video codecs the two ends can negotiate. Raw values are the wire encoding.
public enum Codec: UInt8, Sendable, CaseIterable {
    case h264 = 0
    case hevc = 1
}
