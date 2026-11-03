import XCTest
@testable import GeometryCore

final class DicomTests: XCTestCase {
    private func makeSlice(z:Double, series:String="1.2.3.99", implicit:Bool=false,
                           transferSyntax:String?=nil) -> Data {
        var buffer=[UInt8](repeating:0,count:128)
        buffer += Array("DICM".utf8)
        func append16(_ v:Int) { buffer += [UInt8(v & 255),UInt8((v>>8)&255)] }
        func append32(_ v:Int) { for k in 0..<4 { buffer.append(UInt8((v>>(k*8))&255)) } }
        func append(_ group:Int,_ element:Int,_ vr:String,_ value:[UInt8],explicit:Bool=true) {
            append16(group);append16(element)
            if explicit {
                buffer += Array(vr.utf8)
                if ["OB","OW","OF","SQ","UT","UN"].contains(vr) {
                    buffer += [0,0]; append32(value.count)
                } else { append16(value.count) }
            } else { append32(value.count) }
            buffer += value
        }
        func chars(_ string:String,pad:UInt8=32)->[UInt8] {
            var v=Array(string.utf8)
            if v.count%2 != 0 { v.append(pad) }
            return v
        }
        func us(_ value:Int)->[UInt8] { [UInt8(value&255),UInt8((value>>8)&255)] }
        let ts=transferSyntax ?? (implicit ? "1.2.840.10008.1.2" : "1.2.840.10008.1.2.1")
        append(2,0x10,"UI",chars(ts,pad:0))
        let e = !implicit
        append(0x20,0x0E,"UI",chars(series,pad:0),explicit:e)
        append(0x20,0x32,"DS",chars("10\\20\\\(z)"),explicit:e)
        append(0x20,0x37,"DS",chars("1\\0\\0\\0\\1\\0"),explicit:e)
        append(0x28,0x02,"US",us(1),explicit:e)
        append(0x28,0x04,"CS",chars("MONOCHROME2"),explicit:e)
        append(0x28,0x10,"US",us(2),explicit:e)
        append(0x28,0x11,"US",us(3),explicit:e)
        append(0x28,0x30,"DS",chars("2\\1.5"),explicit:e)
        append(0x28,0x100,"US",us(16),explicit:e)
        append(0x28,0x101,"US",us(12),explicit:e)
        append(0x28,0x102,"US",us(11),explicit:e)
        append(0x28,0x103,"US",us(1),explicit:e)
        append(0x28,0x1052,"DS",chars("-10"),explicit:e)
        append(0x28,0x1053,"DS",chars("2"),explicit:e)
        var pixels:[UInt8]=[]
        for i in 0..<6 { pixels += us(i+Int(z)) }
        append(0x7FE0,0x10,"OW",pixels,explicit:e)
        return Data(buffer)
    }

    func testExplicitAndImplicitDicomSeries() throws {
        for implicit in [false,true] {
            let volume=try DicomSeriesReader.load(files:[makeSlice(z:35,implicit:implicit),
                                                          makeSlice(z:30,implicit:implicit)])
            XCTAssertEqual(volume.dimensions,[3,2,2])
            XCTAssertEqual(volume.affine.originMm,Point3(-10,30,-20))
            XCTAssertEqual(volume.affine.iMm,Point3(-1.5,0,0))
            XCTAssertEqual(volume.affine.jMm,Point3(0,0,-2))
            XCTAssertEqual(volume.affine.kMm,Point3(0,5,0))
            XCTAssertEqual(volume.value(i:2,j:1,k:0),60)
            XCTAssertEqual(volume.value(i:2,j:1,k:1),70)
        }
    }

    func testDicomRejectsUnsupportedCompressionAndMixedSeries() {
        XCTAssertThrowsError(try DicomSeriesReader.load(files:[makeSlice(z:30,transferSyntax:"1.2.840.10008.1.2.4.50"),makeSlice(z:35)]))
        XCTAssertThrowsError(try DicomSeriesReader.load(files:[makeSlice(z:30),makeSlice(z:35,series:"not-same")]))
        XCTAssertThrowsError(try DicomSeriesReader.load(files:[makeSlice(z:30),makeSlice(z:30)]))
        XCTAssertThrowsError(try DicomSeriesReader.load(files:[makeSlice(z:30)]))
    }
}
