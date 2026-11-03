import XCTest
@testable import GeometryCore

final class PlanningArchiveTests: XCTestCase {
    private func makeArchive(volume:VoxelVolume) throws -> PlanningArchive {
        let center=volume.bounds.center
        let entry=center + Point3(12,0,0)
        let target=center + Point3(0,12,0)
        let trajectory=StudyTrajectory(id:"a",name:"Manual candidate",entryMm:entry,targetMm:target)
        return try PlanningArchive(volume:volume,cursorMm:center,entryMm:entry,targetMm:target,
                                   displayedDepthMm:4,
                                   landmarks:[StudyLandmark(id:"nose",name:"Research landmark",pointMm:center)],
                                   candidates:[trajectory])
    }

    func testRoundtripDoesNotEmbedImages() throws {
        let volume=VoxelVolume.syntheticDemo()
        let plan=try makeArchive(volume:volume)
        let bytes=try JSONEncoder().encode(plan)
        XCTAssertLessThan(bytes.count, 4_096)
        let restored=try JSONDecoder().decode(PlanningArchive.self,from:bytes)
        try restored.validate(for:volume)
        XCTAssertEqual(restored.candidates[0].name,"Manual candidate")
        XCTAssertEqual(restored.displayedDepthMm,4)
    }

    func testRejectsDifferentVoxelContentWithSameGeometry() throws {
        let volume=VoxelVolume.syntheticDemo()
        let plan=try makeArchive(volume:volume)
        var changed=volume.voxels
        changed[1000] += 1
        let other=try VoxelVolume(dimensions:volume.dimensions,affine:volume.affine,
                                   voxels:changed,description:"same grid, different image")
        XCTAssertThrowsError(try plan.validate(for:other)) { error in
            guard case PlanningArchiveError.differentImage = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testRejectsOutOfBoundsCoordinates() throws {
        let volume=VoxelVolume.syntheticDemo()
        XCTAssertThrowsError(try PlanningArchive(volume:volume,cursorMm:.init(1e6,0,0),
            entryMm:.init(0,0,0),targetMm:.init(10,0,0),displayedDepthMm:2,
            landmarks:[],candidates:[]))
    }

    func testSampleIntensityProfileAtEndpoints() throws {
        let volume=VoxelVolume.syntheticDemo()
        let line=StudyTrajectory(id:"profile",name:"manual",entryMm:.init(-20,0,0),targetMm:.init(20,0,0))
        let samples=PathSampler.sample(line,volume:volume,spacingMm:2)
        XCTAssertEqual(samples.count,21)
        XCTAssertEqual(samples.first!.distanceMm,0,accuracy:0.00001)
        XCTAssertEqual(samples.last!.distanceMm,40,accuracy:0.00001)
        XCTAssertTrue(samples.allSatisfy { $0.intensity != nil })
    }

    func testRejectsBadSamplingInputs() throws {
        let volume=VoxelVolume.syntheticDemo()
        let zero=StudyTrajectory(id:"zero",name:"zero",entryMm:.init(0,0,0),targetMm:.init(0,0,0))
        XCTAssertTrue(PathSampler.sample(zero,volume:volume).isEmpty)
        let good=StudyTrajectory(id:"good",name:"good",entryMm:.init(0,0,0),targetMm:.init(0,10,0))
        XCTAssertTrue(PathSampler.sample(good,volume:volume,spacingMm:.nan).isEmpty)
    }
}
