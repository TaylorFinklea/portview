import Foundation
import CoreImage
import CoreGraphics

enum TerminalQR {
    /// Render `text` as a QR code drawn with Unicode half-block characters for the terminal.
    /// Composites onto white so module/background detection is unambiguous. Returns nil on failure.
    static func render(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: &pixels, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func isDark(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false } // quiet zone = light
            return pixels[(y * width + x) * 4] < 128
        }

        let margin = 2
        var output = ""
        var y = -margin
        while y < height + margin {
            for x in (-margin)..<(width + margin) {
                switch (isDark(x, y), isDark(x, y + 1)) {
                case (true, true): output += "\u{2588}"   // █
                case (true, false): output += "\u{2580}"  // ▀
                case (false, true): output += "\u{2584}"  // ▄
                case (false, false): output += " "
                }
            }
            output += "\n"
            y += 2
        }
        return output
    }
}
