import Foundation

/// DICOM PS3.5 Annex G RLE Lossless, restricted to single-frame grayscale
/// 8/16-bit images. No lossy conversion or implicit reinterpretation is used.
public enum DicomRLEDecoder {
    public static func decode(_ frame: Data, pixelCount: Int, bitsAllocated: Int) throws -> [UInt8] {
        guard pixelCount > 0, pixelCount <= 4_000_000,
              bitsAllocated == 8 || bitsAllocated == 16,
              frame.count >= 65 && frame.count <= 20_000_000 else { throw ImagingError.invalidPayload }
        let bytes = [UInt8](frame)
        func u32(_ p: Int) -> Int {
            Int(bytes[p]) | Int(bytes[p+1]) << 8 | Int(bytes[p+2]) << 16 | Int(bytes[p+3]) << 24
        }
        let expected = bitsAllocated / 8
        let nSegments = u32(0)
        guard nSegments == expected else {
            throw ImagingError.unsupported("DICOM RLE segment count does not match grayscale bit depth")
        }
        var offsets = (0..<nSegments).map { u32(4 + $0*4) }
        guard offsets[0] == 64 && offsets.allSatisfy({ $0 >= 64 && $0 < bytes.count }) else {
            throw ImagingError.invalidPayload
        }
        offsets.append(bytes.count)
        guard zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else { throw ImagingError.invalidPayload }
        var planes = [[UInt8]]()
        for segment in 0..<nSegments {
            var cursor = offsets[segment]
            let end = offsets[segment+1]
            var output = [UInt8]()
            output.reserveCapacity(pixelCount)
            while cursor < end && output.count < pixelCount {
                let signed = Int(Int8(bitPattern: bytes[cursor])); cursor += 1
                if signed >= 0 {
                    let n = signed+1
                    guard cursor+n <= end && n <= pixelCount-output.count else { throw ImagingError.invalidPayload }
                    output.append(contentsOf: bytes[cursor..<(cursor+n)])
                    cursor += n
                } else if signed >= -127 {
                    let n = 1-signed
                    guard cursor < end && n <= pixelCount-output.count else { throw ImagingError.invalidPayload }
                    output.append(contentsOf: repeatElement(bytes[cursor], count:n))
                    cursor += 1
                }
                // -128 is a PackBits no-op.
            }
            // A single trailing pad byte is allowed for even-length fragments.
            guard output.count == pixelCount,
                  cursor == end || (cursor+1 == end && bytes[cursor] == 0) else {
                throw ImagingError.invalidPayload
            }
            planes.append(output)
        }
        if expected == 1 { return planes[0] }
        var result=[UInt8](repeating:0,count:pixelCount*2)
        for p in 0..<pixelCount {
            result[2*p] = planes[1][p] // DICOM RLE high plane first; native little endian low byte first.
            result[2*p+1] = planes[0][p]
        }
        return result
    }
}
