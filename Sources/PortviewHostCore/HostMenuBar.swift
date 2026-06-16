/// Pure mapping from host state to the menu-bar SF Symbol (in core so it's unit-tested; the app's
/// HostAppModel feeds it live state). Precedence: failed > connected > running(advertising) > idle.
/// Symbols are long-established (macOS 11+) so the template glyph always renders.
public enum HostMenuBar {
    public static func symbol(isFailed: Bool, isRunning: Bool, connectedCount: Int) -> String {
        if isFailed { return "exclamationmark.triangle.fill" }
        if connectedCount > 0 { return "iphone.radiowaves.left.and.right" }
        if isRunning { return "antenna.radiowaves.left.and.right" }
        return "display"
    }
}
