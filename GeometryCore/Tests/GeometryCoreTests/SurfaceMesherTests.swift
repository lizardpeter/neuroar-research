import XCTest
@testable import GeometryCore

final class SurfaceMesherTests: XCTestCase {
    private func makeVolume(_ dimensions:[Int]=[8,8,8],
                            fill:(Int,Int,Int)->Float) throws -> VoxelVolume {
        let affine=try VoxelAffine(originMm:Point3(10,-20,30),
                                   iMm:Point3(2,0,0),jMm:Point3(0,3,0),kMm:Point3(0,0,4))
        var values:[Float]=[]
        for k in 0..<dimensions[2] { for j in 0..<dimensions[1] { for i in 0..<dimensions[0] {
            values.append(fill(i,j,k))
        }}}
        return try VoxelVolume(dimensions:dimensions,affine:affine,voxels:values,description:"synthetic test",isSynthetic:true)
    }

    func testEmptyAndUniformVolumeHaveNoTriangles() throws {
        let empty=try makeVolume { _,_,_ in 0 }
        let full=try makeVolume { _,_,_ in 1 }
        XCTAssertEqual(PreviewSurfaceMesher.extract(volume:empty,threshold:0.5).triangleCount,0)
        XCTAssertEqual(PreviewSurfaceMesher.extract(volume:full,threshold:0.5).triangleCount,0)
    }

    func testSyntheticInteriorCubeProducesSurfaceInMillimeters() throws {
        let v=try makeVolume { i,j,k in (2...5).contains(i) && (2...5).contains(j) && (2...5).contains(k) ? 1 : 0 }
        let surface=PreviewSurfaceMesher.extract(volume:v,threshold:0.5)
        XCTAssertGreaterThan(surface.triangleCount,0)
        XCTAssertEqual(surface.verticesMm.count % 3,0)
        XCTAssertFalse(surface.truncated)
        for p in surface.verticesMm {
            XCTAssertTrue(p.allFinite)
            XCTAssertGreaterThanOrEqual(p.x,10)
            XCTAssertLessThanOrEqual(p.x,24)
            XCTAssertGreaterThanOrEqual(p.y,-20)
            XCTAssertLessThanOrEqual(p.y,1)
            XCTAssertGreaterThanOrEqual(p.z,30)
            XCTAssertLessThanOrEqual(p.z,58)
        }
    }

    func testPreviewSamplingCapsCellsAndTriangleBudget() throws {
        let v=try makeVolume([38,38,38]) { i,j,k in ((i/2+j/2+k/2)%2 == 0) ? 1 : 0 }
        let surface=PreviewSurfaceMesher.extract(volume:v,threshold:0.5,maxCells:100,maxTriangles:15)
        XCTAssertGreaterThan(surface.samplingStepVoxels,1)
        XCTAssertLessThanOrEqual(surface.triangleCount,15)
    }

    func testInvalidThresholdReturnsEmpty() throws {
        let v=try makeVolume { _,_,_ in 1 }
        XCTAssertEqual(PreviewSurfaceMesher.extract(volume:v,threshold:.nan).triangleCount,0)
    }
}
