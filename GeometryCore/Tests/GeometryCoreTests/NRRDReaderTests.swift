import XCTest
import Foundation
@testable import GeometryCore

final class NRRDReaderTests: XCTestCase {
    func testRawLittleEndianLPSOrientationAndValues() throws {
        let header = """
        NRRD0005
        type: short
        dimension: 3
        sizes: 2 2 2
        encoding: raw
        endian: little
        space: left-posterior-superior
        space directions: (-1,0,0) (0,0,1) (0,-1,0)
        space origin: (30,-40,50)

        """
        var data = Data((header + "\n").utf8)
        for x in Int16(-2)...Int16(5) {
            let bits = UInt16(bitPattern: x)
            data.append(contentsOf: [UInt8(truncatingIfNeeded: bits),
                                     UInt8(truncatingIfNeeded: bits >> 8)])
        }
        let image = try NRRDReader.load(data)
        XCTAssertEqual(image.dimensions, [2,2,2])
        XCTAssertEqual(image.voxels[0], -2)
        XCTAssertEqual(image.voxels[7], 5)
        XCTAssertEqual(image.affine.originMm, Point3(-30,50,40))
        XCTAssertEqual(image.affine.iMm, Point3(1,0,0))
        XCTAssertEqual(image.affine.jMm, Point3(0,1,0))
        XCTAssertEqual(image.affine.kMm, Point3(0,0,1))
    }

    func testRejectsDetachedOrUnorientedVolume() {
        let header = """
        NRRD0005
        type: uchar
        dimension: 3
        sizes: 2 2 2
        encoding: raw
        data file: external.raw

        """
        XCTAssertThrowsError(try NRRDReader.load(Data((header + "\n").utf8) + Data(repeating: 0, count: 8)))
    }

    func testRejectsUnknownEndianness() {
        let header = """
        NRRD0005
        type: short
        dimension: 3
        sizes: 2 2 2
        encoding: raw
        space: right-anterior-superior
        space directions: (1,0,0) (0,1,0) (0,0,1)
        space origin: (0,0,0)

        """
        XCTAssertThrowsError(try NRRDReader.load(Data((header + "\n").utf8) + Data(repeating: 0, count: 16)))
    }
}
