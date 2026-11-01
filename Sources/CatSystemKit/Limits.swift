// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// Bounds on what a file's header can make the reader allocate. Game files are untrusted:
/// a size field is checked against these (and against the input it came from) before
/// anything is reserved, so a few bytes can't ask for gigabytes or trap on overflow.
enum Limits {
    /// The most one buffer read from a file may take (256 MiB).
    static let allocation = 256 << 20
    /// The most a picture's frames may take together (1 GiB).
    static let pictureTotal = 1 << 30
    /// The most frames a picture may have.
    static let frames = 4096
    /// Deflate's best ratio is about 1032:1; an inflated size above this is a lie.
    static let deflateRatio = 1032

    /// `width × height × 4`, or nil when either is negative or the buffer would pass
    /// `allocation`.
    static func rgbaBytes(_ width: Int, _ height: Int) -> Int? {
        guard width >= 0, height >= 0 else { return nil }
        let (pixels, o1) = width.multipliedReportingOverflow(by: height)
        let (bytes, o2) = pixels.multipliedReportingOverflow(by: 4)
        guard !o1, !o2, bytes <= allocation else { return nil }
        return bytes
    }

    /// Whether `count` bytes from `start` lie within a buffer of `size` (no overflow).
    static func fits(_ start: Int, _ count: Int, in size: Int) -> Bool {
        guard start >= 0, count >= 0 else { return false }
        let (end, overflow) = start.addingReportingOverflow(count)
        return !overflow && end <= size
    }
}

extension Int {
    /// `value` rounded toward zero, never trapping: NaN is 0 and anything past ±2⁵² is
    /// clamped there (leaving room to add sizes and offsets to it). For numbers that come
    /// from game data, where `Int(_:)` would trap on NaN, infinity or a huge value.
    init<F: BinaryFloatingPoint>(saturating value: F) {
        let limit: F = 4_503_599_627_370_496 // 2^52
        if value.isNaN { self = 0 } else { self = Int(Swift.min(Swift.max(value, -limit), limit)) }
    }
}
