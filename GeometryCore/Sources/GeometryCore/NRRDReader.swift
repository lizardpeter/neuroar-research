import Foundation

/// Strict, bounded support for 3D scalar NRRD files (including Slicer's
/// embedded gzip NRRDs). Converts RAS/LPS voxel directions to NeuroAR's
/// canonical right/superior/anterior millimeter coordinates.
///
/// Large volumes are intentionally isotropically sub-sampled by integer voxel
/// strides, preserving physical location and orientation at retained samples.
/// These are exploratory views, not diagnostic-quality resampling.
public enum NRRDReader {
    public static let maximumSourceBytes = 550_000_000
    public static let maximumPreviewVoxels = 12_000_000

    public static func load(_ data: Data) throws -> VoxelVolume {
        guard data.count >= 16, data.count <= maximumSourceBytes else { throw ImagingError.tooLarge }
        let maxHeader = min(data.count, 131_072)
        var separator: Int?
        var payloadOffset = 0
        var i = 0
        while i < maxHeader {
            if i + 1 < maxHeader && data[i] == 10 && data[i+1] == 10 {
                separator = i
                payloadOffset = i + 2
                break
            }
            if i + 3 < maxHeader && data[i] == 13 && data[i+1] == 10 &&
                data[i+2] == 13 && data[i+3] == 10 {
                separator = i
                payloadOffset = i + 4
                break
            }
            i += 1
        }
        guard let headerEnd = separator,
              let header = String(data: data.subdata(in: 0..<headerEnd), encoding: .utf8),
              header.hasPrefix("NRRD000") else {
            throw ImagingError.invalidHeader("Missing NRRD header and embedded data")
        }
        var fields: [String: String] = [:]
        for line in header.components(separatedBy: .newlines).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":"),
                  trimmed[trimmed.index(after: colon)...].first != "=" else { continue }
            let key = String(trimmed[..<colon]).lowercased()
            fields[key] = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard fields["dimension"] == "3",
              let sizes = fields["sizes"]?.split(whereSeparator: \.isWhitespace)
                .compactMap({ Int($0) }),
              sizes.count == 3, sizes.allSatisfy({ $0 > 1 && $0 <= 2048 }) else {
            throw ImagingError.unsupported("NRRD must be a 3D scalar image with valid sizes")
        }
        guard fields["data file"] == nil, fields["datafile"] == nil else {
            throw ImagingError.unsupported("Detached .nhdr datasets are not supported")
        }
        guard fields["byte skip"] == nil || fields["byte skip"] == "0",
              fields["line skip"] == nil || fields["line skip"] == "0" else {
            throw ImagingError.unsupported("NRRD byte/line skip is not supported")
        }
        if let kinds = fields["kinds"] {
            let v = kinds.split(whereSeparator: \.isWhitespace).map(String.init)
            guard v.count == 3, v.allSatisfy({ $0 == "domain" || $0 == "space" }) else {
                throw ImagingError.unsupported("Only scalar spatial NRRDs are supported")
            }
        }
        let axes: [Double]
        switch fields["space"]?.lowercased() {
        case "left-posterior-superior": axes = [-1, -1, 1]
        case "right-anterior-superior": axes = [1, 1, 1]
        case "left-anterior-superior": axes = [-1, 1, 1]
        case "right-posterior-superior": axes = [1, -1, 1]
        default: throw ImagingError.invalidAffine
        }
        if let units = fields["space units"] {
            let normalized = units.replacingOccurrences(of: "\"", with: "")
                .lowercased().split(whereSeparator: \.isWhitespace)
            guard normalized.count == 3, normalized.allSatisfy({ $0 == "mm" }) else {
                throw ImagingError.unsupported("NRRD space units must be mm")
            }
        }
        func triple(_ text: String) throws -> Point3 {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == "(", trimmed.last == ")" else { throw ImagingError.invalidAffine }
            let values = trimmed.dropFirst().dropLast().split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 3, values.allSatisfy(\.isFinite) else { throw ImagingError.invalidAffine }
            // NRRD axes are (LR, AP, SI). Our axes are (R, S, A).
            return Point3(values[0] * axes[0], values[2], values[1] * axes[1])
        }
        guard let originString = fields["space origin"],
              let directions = fields["space directions"] else { throw ImagingError.invalidAffine }
        let regex = try NSRegularExpression(pattern: #"\([^)]+\)|none"#)
        let ns = directions as NSString
        let matches = regex.matches(in: directions, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 3 else { throw ImagingError.invalidAffine }
        let vectors = try matches.map { try triple(ns.substring(with: $0.range)) }
        let origin = try triple(originString)

        enum Scalar {
            case u8, i8, u16, i16, u32, i32, f32, f64
            var width: Int {
                switch self {
                case .u8, .i8: return 1
                case .u16, .i16: return 2
                case .u32, .i32, .f32: return 4
                case .f64: return 8
                }
            }
        }
        let scalar: Scalar
        switch fields["type"]?.lowercased() {
        case "unsigned char", "uchar", "uint8", "uint8_t": scalar = .u8
        case "char", "signed char", "int8", "int8_t": scalar = .i8
        case "unsigned short", "ushort", "uint16", "uint16_t": scalar = .u16
        case "short", "signed short", "int16", "int16_t": scalar = .i16
        case "unsigned int", "uint", "uint32", "uint32_t": scalar = .u32
        case "int", "signed int", "int32", "int32_t": scalar = .i32
        case "float": scalar = .f32
        case "double": scalar = .f64
        default: throw ImagingError.unsupported("Unsupported NRRD scalar type")
        }
        let littleEndian: Bool
        if scalar.width == 1 {
            littleEndian = true
        } else {
            switch fields["endian"]?.lowercased() {
            case "little": littleEndian = true
            case "big": littleEndian = false
            default: throw ImagingError.invalidHeader("NRRD endian must be explicit")
            }
        }
        let encoding = fields["encoding"]?.lowercased()
        guard encoding == "raw" || encoding == "gzip" || encoding == "gz" else {
            throw ImagingError.unsupported("Only raw and gzip NRRDs are supported")
        }
        let source: Data
        let byteStart: Int
        if encoding == "gzip" || encoding == "gz" {
            let compressed = data.subdata(in: payloadOffset..<data.count)
            source = try CompressedNiftiReader.inflateGzip(compressed)
            byteStart = 0
        } else {
            source = data
            byteStart = payloadOffset
        }
        let (xy, overflowXY) = sizes[0].multipliedReportingOverflow(by: sizes[1])
        let (count, overflowXYZ) = xy.multipliedReportingOverflow(by: sizes[2])
        guard !overflowXY, !overflowXYZ,
              count <= maximumSourceBytes / scalar.width,
              byteStart <= source.count,
              count * scalar.width <= source.count - byteStart else {
            throw ImagingError.invalidPayload
        }

        var step = 1
        func decimated(_ d: Int) -> Int { (d + step - 1) / step }
        while decimated(sizes[0]) * decimated(sizes[1]) * decimated(sizes[2]) > maximumPreviewVoxels {
            step += 1
        }
        let dims = sizes.map(decimated)
        var voxels = [Float](repeating: 0, count: dims[0] * dims[1] * dims[2])
        source.withUnsafeBytes { raw in
            func word(_ at: Int, _ width: Int) -> UInt64 {
                var value: UInt64 = 0
                for b in 0..<width {
                    let shift = UInt64(littleEndian ? b : width - 1 - b) * 8
                    value |= UInt64(raw[at+b]) << shift
                }
                return value
            }
            for k in 0..<dims[2] {
                for j in 0..<dims[1] {
                    for i in 0..<dims[0] {
                        let src = (k * step * sizes[1] * sizes[0] +
                                   j * step * sizes[0] + i * step) * scalar.width + byteStart
                        let n = word(src, scalar.width)
                        let v: Double
                        switch scalar {
                        case .u8, .u16, .u32: v = Double(n)
                        case .i8: v = Double(Int8(bitPattern: UInt8(truncatingIfNeeded: n)))
                        case .i16: v = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: n)))
                        case .i32: v = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: n)))
                        case .f32: v = Double(Float(bitPattern: UInt32(truncatingIfNeeded: n)))
                        case .f64: v = Double(bitPattern: n)
                        }
                        voxels[(k * dims[1] + j) * dims[0] + i] =
                            v.isFinite ? Float(max(-Double(Float.greatestFiniteMagnitude),
                                                  min(Double(Float.greatestFiniteMagnitude), v))) : 0
                    }
                }
            }
        }
        let factor = Double(step)
        let affine = try VoxelAffine(originMm: origin,
                                     iMm: vectors[0] * factor,
                                     jMm: vectors[1] * factor,
                                     kMm: vectors[2] * factor)
        let detail = step == 1 ? "native sampling" : "preview every \(step) voxels; not diagnostic resolution"
        return try VoxelVolume(dimensions: dims, affine: affine, voxels: voxels,
                               description: "NRRD · \(dims.map(String.init).joined(separator: "×")) · \(detail)")
    }
}
