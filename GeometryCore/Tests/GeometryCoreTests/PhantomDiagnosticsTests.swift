import XCTest
@testable import GeometryCore

final class PhantomDiagnosticsTests: XCTestCase {
    func testNoRawCoordinatesOrIdentifyingDataAreSerialized() throws {
        let points=(0..<100).map { i in Point3(Double(i)*0.001,Double(i%7)*0.002,0.003) }
        let stats=try XCTUnwrap(PhantomDepthStatistics.analyze(points))
        XCTAssertEqual(stats.sampleCount,100)
        XCTAssertGreaterThan(stats.spatialSpreadMm,0)
        let json=String(data:try JSONEncoder().encode(stats),encoding:.utf8)!
        XCTAssertFalse(json.contains("pointMm"))
        XCTAssertFalse(json.contains("coordinates"))
    }

    func testRejectsSparseOrNonFiniteClouds() {
        XCTAssertNil(PhantomDepthStatistics.analyze([Point3](repeating:.init(0,0,0),count:2)))
        XCTAssertNil(PhantomDepthStatistics.analyze([Point3](repeating:.init(0,.nan,0),count:50)))
    }
}
