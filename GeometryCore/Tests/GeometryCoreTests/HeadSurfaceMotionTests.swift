import XCTest
@testable import GeometryCore

final class HeadSurfaceMotionTests: XCTestCase {
    /// Irregular, non-symmetric curved phantom patch (not actual patient data).
    private var reference: [Point3] {
        var points: [Point3] = []
        for y in 0..<20 {
            for x in 0..<20 {
                let u = (Double(x) - 9.5) * 0.0075
                let v = (Double(y) - 9.5) * 0.0085
                let z = 0.38 + 0.35*u*u + 0.46*v*v + 0.017*sin(20*u) + 0.009*cos(15*v)
                points.append(.init(u + 0.13, v - 0.02, z))
            }
        }
        return points
    }

    func testSmallTranslationWithIrregularPhantomSurface() throws {
        let shift = Point3(0.006, -0.004, 0.003)
        let moved = reference.map { $0 + shift }
        let report = try HeadSurfaceMotion.estimate(previousMeters: reference, currentMeters: moved)
        XCTAssertGreaterThan(report.matchedCount, 100)
        XCTAssertLessThan(report.fittedRMSEMeters, 0.008)
        XCTAssertLessThan((report.delta.transform(reference[109]) - moved[109]).norm, 0.008)
    }

    func testPartialOcclusionRetainsEnoughIrregularSurface() throws {
        let visible = reference.filter { $0.x > 0.103 }.map { $0 + Point3(0.002, -0.003, 0.002) }
        XCTAssertGreaterThan(visible.count, 80)
        let result = try HeadSurfaceMotion.estimate(previousMeters: reference,
                                                     currentMeters: visible)
        XCTAssertGreaterThan(result.matchedCount, 55)
        XCTAssertLessThan(result.fittedRMSEMeters, 0.009)
    }

    func testRejectsNonFiniteSurfaceAndBackgroundOnly() throws {
        XCTAssertThrowsError(try HeadSurfaceMotion.estimate(previousMeters: reference,
            currentMeters: Array(repeating: Point3(0.12, 0, 0.4), count: 200)))
        let invalid = Array(repeating: Point3(Double.nan, 0, 0), count: 100)
        XCTAssertThrowsError(try HeadSurfaceMotion.estimate(previousMeters: reference, currentMeters: invalid))
        XCTAssertThrowsError(try HeadSurfaceMotion.estimate(previousMeters: reference,
            currentMeters: reference.map { $0 + Point3(0.25, 0, 0) }))
    }

    func testRejectsSparseOrPlanarSurface() throws {
        XCTAssertThrowsError(try HeadSurfaceMotion.estimate(previousMeters: Array(reference.prefix(40)),
            currentMeters: reference))
        let flat = reference.map { Point3($0.x, $0.y, 0.38) }
        XCTAssertThrowsError(try HeadSurfaceMotion.estimate(previousMeters: flat, currentMeters: flat))
    }
}
