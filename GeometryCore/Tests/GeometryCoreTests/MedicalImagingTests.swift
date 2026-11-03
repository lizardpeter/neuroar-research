import XCTest
@testable import GeometryCore

final class MedicalImagingTests: XCTestCase {
    // Fixture writer deliberately independent of the production reader.
    private func niftiFixture(bigEndian:Bool=false, sform:Bool=true, qform:Bool=false,
                              badMagic:Bool=false) -> Data {
        var bytes=[UInt8](repeating:0,count:352+3*4*2*2)
        func put16(_ o:Int,_ v:UInt16) {
            bytes[o]=UInt8(truncatingIfNeeded:bigEndian ? (v>>8) : v)
            bytes[o+1]=UInt8(truncatingIfNeeded:bigEndian ? v : (v>>8))
        }
        func put32(_ o:Int,_ v:UInt32) {
            if bigEndian { for i in 0..<4 { bytes[o+i]=UInt8(truncatingIfNeeded:v>>(24-8*i)) } }
            else { for i in 0..<4 { bytes[o+i]=UInt8(truncatingIfNeeded:v>>(8*i)) } }
        }
        func putFloat(_ o:Int,_ v:Float) { put32(o,v.bitPattern) }
        put32(0,348);put16(40,3);put16(42,3);put16(44,4);put16(46,2)
        put16(70,4);put16(72,16);putFloat(108,352)
        putFloat(112,2);putFloat(116,-5)
        bytes[123]=2 // spatial units = millimeters
        bytes[344]=badMagic ? 0 : 110;bytes[345]=43;bytes[346]=49;bytes[347]=0
        if sform {
            put16(254,1)
            // RAS axes: +R along i, +A along j, +S along k.
            for (at,v) in [(280,2.0 as Float),(284,0),(288,0),(292,10),
                           (296,0),(300,3),(304,0),(308,20),
                           (312,0),(316,0),(320,4),(324,30)] { putFloat(at,v) }
        }
        if qform {
            put16(252,1)
            putFloat(80,2);putFloat(84,3);putFloat(88,4)
            putFloat(268,10);putFloat(272,20);putFloat(276,30)
        }
        for n in 0..<24 { put16(352+n*2,UInt16(n)) }
        return Data(bytes)
    }

    func testNiftiSformCoordinatesAndScaling() throws {
        let volume=try NiftiReader.load(niftiFixture())
        XCTAssertEqual(volume.dimensions,[3,4,2])
        let origin=volume.affine.point(i:0,j:0,k:0)
        XCTAssertEqual(origin,Point3(10,30,20))
        let world=volume.affine.point(i:1,j:2,k:1)
        XCTAssertEqual(world,Point3(12,34,26))
        XCTAssertEqual(volume.value(i:2,j:3,k:1),41)
        XCTAssertEqual(volume.affine.index(of:world).x,1,accuracy:1e-8)
        XCTAssertEqual(volume.affine.index(of:world).y,2,accuracy:1e-8)
        XCTAssertEqual(volume.affine.index(of:world).z,1,accuracy:1e-8)
    }

    func testNiftiQformCoordinates() throws {
        let volume=try NiftiReader.load(niftiFixture(sform:false,qform:true))
        let world=volume.affine.point(i:1,j:2,k:1)
        XCTAssertEqual(world.x,12,accuracy:1e-8)
        XCTAssertEqual(world.y,34,accuracy:1e-8)
        XCTAssertEqual(world.z,26,accuracy:1e-8)
    }

    func testBigEndianNifti() throws {
        let volume=try NiftiReader.load(niftiFixture(bigEndian:true))
        XCTAssertEqual(volume.value(i:2,j:3,k:1),41)
        XCTAssertEqual(volume.affine.point(i:1,j:2,k:1),Point3(12,34,26))
    }

    func testNiftiRejectsUnorientedAndMalformedData() {
        XCTAssertThrowsError(try NiftiReader.load(niftiFixture(sform:false,qform:false)))
        XCTAssertThrowsError(try NiftiReader.load(niftiFixture(badMagic:true)))
        XCTAssertThrowsError(try NiftiReader.load(niftiFixture().prefix(365)))
    }

    func testTrilinearSamplesAndSliceProjection() throws {
        let affine=try VoxelAffine(originMm:Point3(10,20,30),iMm:Point3(2,0,0),
                                   jMm:Point3(0,0,2),kMm:Point3(0,2,0))
        var samples=[Float](repeating:0,count:8)
        for k in 0..<2 { for j in 0..<2 { for i in 0..<2 {
            samples[(k*2+j)*2+i]=Float(i*10+j*20+k*40)
        }}}
        let volume=try VoxelVolume(dimensions:[2,2,2],affine:affine,voxels:samples,description:"test")
        XCTAssertEqual(volume.trilinear(at:Point3(11,21,31))!,35,accuracy:1e-6)
        XCTAssertNil(volume.trilinear(at:Point3(99,99,99)))
        for plane in ImagingPlane.allCases {
            let cursor=Point3(11,21,31)
            let frame=SliceFrame(plane:plane,bounds:volume.bounds,cursor:cursor)
            let uv=frame.uv(for:cursor)
            let projected=frame.world(u:uv.u,v:uv.v)
            XCTAssertEqual(projected.x,cursor.x,accuracy:1e-8)
            XCTAssertEqual(projected.y,cursor.y,accuracy:1e-8)
            XCTAssertEqual(projected.z,cursor.z,accuracy:1e-8)
            let raster=SliceRenderer.render(volume:volume,mask:nil,plane:plane,cursor:cursor,
                                            window:0...70,width:32,height:32)
            XCTAssertEqual(raster.rgba.count,32*32*4)
            XCTAssertEqual(raster.rgba[3],255)
        }
    }

    func testTrajectoryMaskSamplingIsNotClearance() throws {
        let affine=try VoxelAffine(originMm:Point3(0,0,0),iMm:Point3(1,0,0),
                                   jMm:Point3(0,1,0),kMm:Point3(0,0,1))
        let mask=try VoxelVolume(dimensions:[11,3,3],affine:affine,
                                 voxels:(0..<99).map { ($0%11>=4 && $0%11<=6) ? 1 : 0 },description:"mask")
        let path=StudyTrajectory(id:"a",name:"synthetic",entryMm:Point3(0,1,1),targetMm:Point3(10,1,1))
        let result=TrajectoryMaskSampler.analyze(path,mask:mask,referenceVolume:mask)
        XCTAssertEqual(result.pointsInsideMask,3)
        XCTAssertEqual(result.firstIntersectionDepthMm,4)
        XCTAssertFalse(result.anyOutOfVolume)
        let outside=StudyTrajectory(id:"b",name:"synthetic",entryMm:Point3(-5,1,1),targetMm:Point3(10,1,1))
        XCTAssertTrue(TrajectoryMaskSampler.analyze(outside,mask:mask,referenceVolume:mask).anyOutOfVolume)
    }
}
