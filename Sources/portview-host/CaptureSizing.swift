struct CaptureSizing {
    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    static func outputSize(width: Int, height: Int, pointPixelScale: Float) -> Size {
        let scale = max(1.0, Double(pointPixelScale))
        return Size(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }
}
