import XCTest
@testable import GeometryCore

final class SurfaceRegistrationTests: XCTestCase {
    func testSeededSurfaceConvergesOnAsymmetricCloud() throws {
        let source:[Point3]=(0..<80).map { i in
            let a=Double(i)
            return Point3(0.06*sin(a*0.77),0.04*cos(a*0.41),0.03*sin(a*0.27)+0.01*cos(a*1.17))
        }
        let translation=Point3(0.15,-0.03,0.22)
        let shifted=source.map { $0+translation }
        let seed=try RigidRegistration.fit(sourceMeters:Array(source.prefix(4)),
                                           targetMeters:Array(shifted.prefix(4)).map { $0+Point3(0.002,-0.001,0.001) })
        let report=try TrimmedSurfaceICP.refine(sourceMeters:source,observedMeters:shifted,initial:seed)
        XCTAssertLessThan(report.fittedRMSEMeters,0.001)
        XCTAssertLessThan((report.transform.translationMeters-translation).norm,0.003)
        XCTAssertGreaterThan(report.matchedPointCount,30)
    }

    func testRejectsNoCorrespondencesAndInputWithNaN() throws {
        let source:[Point3]=(0..<25).map { i in Point3(Double(i)*0.001,Double(i*i)*0.0001,0) }
        let seed=try RigidRegistration.fit(sourceMeters:source,targetMeters:source)
        XCTAssertThrowsError(try TrimmedSurfaceICP.refine(sourceMeters:source,
                                                          observedMeters:source.map { $0+Point3(1,1,1) },initial:seed))
        XCTAssertThrowsError(try TrimmedSurfaceICP.refine(sourceMeters:source+[Point3(.nan,0,0)],
                                                          observedMeters:source,initial:seed))
    }
}
