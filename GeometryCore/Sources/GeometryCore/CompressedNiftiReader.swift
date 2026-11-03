import Foundation
import CZlib

/// Strict, bounded GZIP decoding for NIfTI-1 `.nii.gz` files.
/// The zlib GZIP mode checks the member trailer/CRC and rejects truncated streams.
/// Patient images remain in memory and are never transmitted by this importer.
public enum CompressedNiftiReader {
    public static let maximumUncompressedBytes = 550_000_000

    public static func load(_ data: Data) throws -> VoxelVolume {
        let isGzip = data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
        return try NiftiReader.load(isGzip ? inflateGzip(data) : data)
    }

    public static func inflateGzip(_ data: Data, limit: Int = maximumUncompressedBytes) throws -> Data {
        guard data.count >= 20, data.count <= maximumUncompressedBytes,
              data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b,
              limit > 0 && limit <= maximumUncompressedBytes else {
            throw ImagingError.invalidPayload
        }
        var stream = z_stream()
        let result = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else { throw ImagingError.invalidPayload }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunkSize = 64 * 1024
        let status: Int32 = data.withUnsafeBytes { raw in
            guard let input = raw.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(raw.count)
            var status: Int32 = Z_OK
            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > limit - output.count { return Z_MEM_ERROR }
                output.append(contentsOf: chunk.prefix(produced))
                if status != Z_OK && status != Z_STREAM_END { return status }
                if produced == 0 && status == Z_OK && stream.avail_in == 0 { return Z_DATA_ERROR }
            } while status != Z_STREAM_END
            // Reject extra members and trailing unverified bytes: do not silently
            // accept a second file masquerading as part of the scan.
            return stream.avail_in == 0 ? status : Z_DATA_ERROR
        }
        guard status == Z_STREAM_END else {
            if status == Z_MEM_ERROR { throw ImagingError.tooLarge }
            throw ImagingError.invalidPayload
        }
        return output
    }
}
