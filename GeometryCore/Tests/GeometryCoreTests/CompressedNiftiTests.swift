import XCTest
@testable import GeometryCore

final class CompressedNiftiTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "synthetic-phantom.nii", withExtension: "gz"))
        return try Data(contentsOf: url)
    }

    func testGzipNiftiCoordinatesAndVoxels() throws {
        let compressed = try fixture()
        let expanded = try CompressedNiftiReader.inflateGzip(compressed)
        let plain = try NiftiReader.load(expanded)
        let gz = try CompressedNiftiReader.load(compressed)
        XCTAssertEqual(gz.dimensions, plain.dimensions)
        XCTAssertEqual(gz.affine.originMm, plain.affine.originMm)
        XCTAssertEqual(gz.voxels, plain.voxels)
    }

    func testRejectsTruncationCorruptionAndOutputLimit() throws {
        let file = try fixture()
        XCTAssertThrowsError(try CompressedNiftiReader.inflateGzip(Data(file.dropLast(7))))
        var bad = file
        bad[bad.count - 6] ^= 0x40
        XCTAssertThrowsError(try CompressedNiftiReader.inflateGzip(bad))
        XCTAssertThrowsError(try CompressedNiftiReader.inflateGzip(file, limit: 100))
        XCTAssertThrowsError(try CompressedNiftiReader.inflateGzip(file + Data([0,1])))
    }
}
