import XCTest
@testable import GeometryCore

final class RegistrationEvaluationTests:XCTestCase {
    private let landmarks:[Point3]=[
        .init(-0.03,0.02,0.09),.init(0.03,0.02,0.09),
        .init(0,-0.04,0.06),.init(0.01,0.05,0.04)
    ]
    func testFourthPointExcludedAndExternallyValidated() throws {
        let t=Point3(0.2,-0.1,0.5)
        var observed=landmarks.map { $0+t }
        observed[3].x += 0.018  // Mimic inaccurate physical capture of a held-out landmark.
        let report=try LandmarkRegistrationEvaluator.evaluate(sourceMeters:landmarks,targetMeters:observed)
        XCTAssertEqual(report.fittedPointCount,3)
        XCTAssertTrue(report.hasHeldOutPoint)
        XCTAssertLessThan(report.fit.landmarkRMSEmeters,1e-8)
        XCTAssertEqual(report.heldOutSurfaceResidualMeters!,0.018,accuracy:1e-8)
    }
    func testThreePointRegistrationIsNotIndependentlyChecked() throws {
        let report=try LandmarkRegistrationEvaluator.evaluate(
            sourceMeters:Array(landmarks.prefix(3)),targetMeters:Array(landmarks.prefix(3)))
        XCTAssertFalse(report.hasHeldOutPoint)
        XCTAssertNil(report.heldOutSurfaceResidualMeters)
        XCTAssertEqual(report.fit.count,3)
    }
    func testRejectsNonFiniteHeldoutPoint() throws {
        var b=landmarks
        b[3].z = .infinity
        XCTAssertThrowsError(try LandmarkRegistrationEvaluator.evaluate(sourceMeters:landmarks,targetMeters:b))
    }
}
