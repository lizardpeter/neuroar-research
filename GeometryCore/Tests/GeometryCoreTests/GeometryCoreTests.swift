import XCTest
@testable import GeometryCore

final class GeometryCoreTests: XCTestCase {
    func testRigidRegistrationTranslationAndZRotation() throws {
        let a = [Point3(0,0,0), Point3(0.07,0,0), Point3(0,0.06,0), Point3(0,0,0.04)]
        let shift = Point3(0.34,-0.20,0.95)
        let b = a.map { Point3(-$0.y,$0.x,$0.z) + shift }
        let result = try RigidRegistration.fit(sourceMeters:a,targetMeters:b)
        XCTAssertLessThan(result.landmarkRMSEmeters, 1e-9)
        for (src, dest) in zip(a,b) {
            XCTAssertLessThan((result.transform(src)-dest).norm, 1e-8)
        }
    }
    func testRejectCollinearPoints() {
        let points=[Point3(0,0,0),Point3(0.01,0,0),Point3(0.02,0,0)]
        XCTAssertThrowsError(try RigidRegistration.fit(sourceMeters:points,targetMeters:points))
    }
    func testTrajectoryDepthClamps() {
        let t=StudyTrajectory(id:"x",name:"example",entryMm:Point3(0,0,0),targetMm:Point3(0,0,50))
        XCTAssertEqual(t.atDepth(25).z,25,accuracy:1e-10)
        XCTAssertEqual(t.atDepth(100).z,50,accuracy:1e-10)
        XCTAssertEqual(t.atDepth(-10).z,0,accuracy:1e-10)
    }
}
