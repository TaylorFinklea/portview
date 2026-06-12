struct CaptureSizing {
    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    static func outputSize(width: Int, height: Int, pointPixelScale _: Float) -> Size {
        Size(width: max(1, width), height: max(1, height))
    }
}
