import Foundation
import CoreVideo

/// Create an IOSurface-backed BGRA pixel buffer filled with a solid colour.
func makeSolidBGRA(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            base[offset + 0] = b
            base[offset + 1] = g
            base[offset + 2] = r
            base[offset + 3] = 255
        }
    }
    return buffer
}

/// Read the centre pixel of a BGRA pixel buffer as (b, g, r).
func centerPixelBGRA(_ buffer: CVPixelBuffer) -> (b: UInt8, g: UInt8, r: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let x = CVPixelBufferGetWidth(buffer) / 2
    let y = CVPixelBufferGetHeight(buffer) / 2
    let offset = y * bytesPerRow + x * 4
    return (base[offset + 0], base[offset + 1], base[offset + 2])
}
