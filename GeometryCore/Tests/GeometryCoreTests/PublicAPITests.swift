import XCTest
import GeometryCore

/// Compile a consumer using *public* GeometryCore APIs, not @testable imports.
/// The iOS application is a separate module and must be able to instantiate
/// these models without relying on an internal synthesized memberwise init.
final class PublicAPITests: XCTestCase {
    func testCrossModuleStudyConstructionAndSerialization() throws {
        let landmark=StudyLandmark(id:"a",name:"Surface point",pointMm:Point3(0,0,0))
        let path=StudyTrajectory(id:"b",name:"Manual geometric line",
                                 entryMm:Point3(0,0,1),targetMm:Point3(0,0,40))
        let study=Study(id:"study",title:"Synthetic tests",isSynthetic:true,
                        landmarks:[landmark],trajectories:[path])
        XCTAssertEqual(study.landmarks[0].id,"a")
        XCTAssertEqual(study.trajectories[0].lengthMm,39,accuracy:1e-8)
        let restored=try JSONDecoder().decode(Study.self,from:JSONEncoder().encode(study))
        XCTAssertEqual(restored.title,"Synthetic tests")
    }
}
