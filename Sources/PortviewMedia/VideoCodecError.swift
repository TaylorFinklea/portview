// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Errors from the VideoToolbox encode/decode wrappers.
public enum VideoCodecError: Error {
    case sessionCreateFailed(OSStatus)
    case encodeFailed(OSStatus)
    case decodeFailed(OSStatus)
    case noOutput
}
