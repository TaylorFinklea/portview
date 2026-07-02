import PortviewProtocol

/// Pure display-choice rules for the client session.
public enum DisplaySelection {
    /// Resolve which display stays active after the host re-advertises its display list mid-session
    /// (a monitor connected/woke/was removed). Keep the current one if it's still offered; otherwise
    /// fall back to the first so the UI stays consistent. An empty list leaves the current id untouched.
    public static func resolvedActiveDisplay(current: UInt32, among displays: [DisplayInfo]) -> UInt32 {
        if displays.contains(where: { $0.id == current }) { return current }
        return displays.first?.id ?? current
    }
}
