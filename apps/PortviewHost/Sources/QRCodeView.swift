// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

/// A real QR code generated from the pairing URL (the mock's QR is representational). Rendered in
/// the Glass language: signal-teal modules on the dark tile color, crisp (no interpolation).
struct QRCodeView: View {
    let string: String

    var body: some View {
        Group {
            if let image = Self.makeImage(from: string) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Glass.signal)
                    .padding(24)
            }
        }
    }

    private static func makeImage(from string: String) -> NSImage? {
        let context = CIContext()
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(string.utf8)
        generator.correctionLevel = "M"
        guard let code = generator.outputImage else { return nil }

        // Recolor: black modules → signal teal, white background → the dark tile (#0A1416).
        let tint = CIFilter.falseColor()
        tint.inputImage = code
        tint.color0 = CIColor(red: 127 / 255, green: 233 / 255, blue: 208 / 255)
        tint.color1 = CIColor(red: 10 / 255, green: 20 / 255, blue: 22 / 255)
        guard let colored = tint.outputImage else { return nil }

        let scaled = colored.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
