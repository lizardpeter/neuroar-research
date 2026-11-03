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

    /// Convert a self-written uncompressed grayscale slice into a single-frame
    /// DICOM RLE Lossless Part 10 object, independently of the decoder.
    private func makeRLESlice(z: Double) -> Data {
        var source=[UInt8](makeSlice(z:z))
        let original=Array("1.2.840.10008.1.2.1".utf8)
        let compressed=Array("1.2.840.10008.1.2.5".utf8)
        if let uidRange=source.firstIndexOfBytes(original) {
            source.replaceSubrange(uidRange..<(uidRange+original.count),with:compressed)
        }
        let pixelTag:[UInt8]=[0xE0,0x7F,0x10,0x00]
        let start=source.firstIndexOfBytes(pixelTag)!
        let pixels=Array(source.suffix(12))
        let high=(0..<6).map { pixels[$0*2+1] }
        let low=(0..<6).map { pixels[$0*2] }
        var frame=[UInt8](repeating:0,count:64)
        func set32(_ n:Int,_ at:Int) {
            for i in 0..<4 { frame[at+i]=UInt8(truncatingIfNeeded:n >> (8*i)) }
        }
        set32(2,0); set32(64,4); set32(71,8)
        frame += [5] + high + [5] + low
        var end:[UInt8]=pixelTag+Array("OB".utf8)+[0,0,255,255,255,255]
        func push16(_ value:Int) { end += [UInt8(value&255),UInt8((value>>8)&255)] }
        func push32(_ value:Int) { for i in 0..<4 { end.append(UInt8((value>>(8*i))&255)) } }
        push16(0xFFFE);push16(0xE000);push32(0) // empty basic offset table
        push16(0xFFFE);push16(0xE000);push32(frame.count)
        end += frame
        push16(0xFFFE);push16(0xE0DD);push32(0)
        return Data(source.prefix(start)+end)
    }

    func testRLELosslessSeriesMatchesUncompressedExactly() throws {
        let raw=try DicomSeriesReader.load(files:[makeSlice(z:30),makeSlice(z:35)])
        let rle=try DicomSeriesReader.load(files:[makeRLESlice(z:30),makeRLESlice(z:35)])
        XCTAssertEqual(rle.voxels,raw.voxels)
        XCTAssertEqual(rle.dimensions,raw.dimensions)
        XCTAssertEqual(rle.affine.originMm,raw.affine.originMm)
    }

    func testRLERejectsTruncatedAndMismatchedSegments() throws {
        let full=makeRLESlice(z:30)
        XCTAssertThrowsError(try DicomSeriesReader.load(files:[full,Data(full.dropLast(9))]))
        var bad=full
        let bytes=[UInt8](bad)
        // The RLE frame begins 64 bytes after its segment count; break its count.
        let marker:[UInt8]=[2,0,0,0,64,0,0,0,71,0,0,0]
        if let i=bytes.firstIndexOfBytes(marker) {
            bad[i]=3
        }
        XCTAssertThrowsError(try DicomSeriesReader.load(files:[full,bad]))
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

private extension Array where Element == UInt8 {
    func firstIndexOfBytes(_ needle:[UInt8])->Int? {
        guard !needle.isEmpty,count>=needle.count else { return nil }
        for start in 0...(count-needle.count) {
            if self[start..<(start+needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }
}
