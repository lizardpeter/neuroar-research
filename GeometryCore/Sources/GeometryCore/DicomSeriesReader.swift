import Foundation

/// A deliberately narrow DICOM reader for conventional, single-frame, uncompressed
/// monochrome MR image series. All unsupported transfer syntaxes are hard failures.
/// This does not handle enhanced multiframe MRI, compressed data, mosaics, or SEG.
public enum DicomSeriesReader {
    private struct Slice: Sendable {
        let seriesUID:String
        let columns:Int
        let rows:Int
        let rowSpacingMm:Double
        let columnSpacingMm:Double
        let rowDirectionLPS:Point3
        let columnDirectionLPS:Point3
        let positionLPS:Point3
        let pixels:[Float]
    }

    public static func load(files: [Data]) throws -> VoxelVolume {
        guard files.count>=2 else { throw ImagingError.unsupported("select at least two DICOM slices belonging to one series") }
        guard files.count<=2048 else { throw ImagingError.tooLarge }
        let slices=try files.map { try readSlice($0) }
        let first=slices[0]
        let row=first.rowDirectionLPS, col=first.columnDirectionLPS
        let rowNorm=row.norm, colNorm=col.norm
        let orthogonality=row.x*col.x+row.y*col.y+row.z*col.z
        guard abs(rowNorm-1)<0.01,abs(colNorm-1)<0.01,abs(orthogonality)<0.01 else { throw ImagingError.invalidAffine }
        let normal=Point3(row.y*col.z-row.z*col.y,row.z*col.x-row.x*col.z,row.x*col.y-row.y*col.x)
        func dot(_ a:Point3,_ b:Point3)->Double { a.x*b.x+a.y*b.y+a.z*b.z }
        for slice in slices {
            guard slice.seriesUID == first.seriesUID,
                  slice.columns == first.columns, slice.rows == first.rows,
                  abs(slice.rowSpacingMm-first.rowSpacingMm)<0.001,
                  abs(slice.columnSpacingMm-first.columnSpacingMm)<0.001,
                  (slice.rowDirectionLPS-row).norm<0.001,
                  (slice.columnDirectionLPS-col).norm<0.001 else {
                throw ImagingError.unsupported("mixed series, image matrix, pixel spacing, or orientation")
            }
        }
        let sorted=slices.sorted { dot($0.positionLPS,normal)<dot($1.positionLPS,normal) }
        let k=sorted[1].positionLPS-sorted[0].positionLPS
        guard dot(k,normal)>0.01 else { throw ImagingError.invalidAffine }
        for (index,slice) in sorted.enumerated() {
            let expected=sorted[0].positionLPS+k*Double(index)
            guard (slice.positionLPS-expected).norm < max(0.05,k.norm*0.05) else {
                throw ImagingError.unsupported("irregular, overlapping, or missing slice positions; resample externally")
            }
        }
        guard first.columns*first.rows*sorted.count <= 32_000_000 else { throw ImagingError.tooLarge }
        // Standard DICOM patient space is LPS; convert to explicit R/S/A mm frame.
        func canonical(_ p:Point3)->Point3 { Point3(-p.x,p.z,-p.y) }
        let affine=try VoxelAffine(originMm:canonical(sorted[0].positionLPS),
                                   iMm:canonical(row*first.columnSpacingMm),
                                   jMm:canonical(col*first.rowSpacingMm),
                                   kMm:canonical(k))
        return try VoxelVolume(dimensions:[first.columns,first.rows,sorted.count],
                               affine:affine,voxels:sorted.flatMap { $0.pixels },
                               description:"DICOM MR · \(first.columns)×\(first.rows)×\(sorted.count) · validated grayscale")
    }

    private static func readSlice(_ data:Data) throws -> Slice {
        guard data.count>=132,data.count<=20_000_000 else { throw ImagingError.invalidPayload }
        let bytes=[UInt8](data)
        guard String(bytes:bytes[128..<132],encoding:.ascii)=="DICM" else {
            throw ImagingError.unsupported("requires a DICOM Part 10 file with DICM preamble")
        }
        func u16(_ at:Int)->UInt16 { UInt16(bytes[at]) | (UInt16(bytes[at+1])<<8) }
        func u32(_ at:Int)->UInt32 { UInt32(u16(at)) | (UInt32(u16(at+2))<<16) }
        func tag(_ o:Int)->UInt32 { (UInt32(u16(o))<<16) | UInt32(u16(o+2)) }
        var pos=132
        var transferSyntax:String?
        var fields:[UInt32:[UInt8]]=[:]
        let desired:Set<UInt32> = [
            0x0020000E,0x00200032,0x00200037,0x00280002,0x00280004,0x00280008,
            0x00280010,0x00280011,0x00280030,0x00280100,0x00280101,0x00280102,
            0x00280103,0x00281052,0x00281053
        ]
        let longVRs:Set<String>=["OB","OD","OF","OL","OV","OW","SQ","UC","UR","UT","UN","SV","UV"]
        func parseElement(explicit:Bool) throws -> (tag:UInt32,valueStart:Int,valueLength:Int) {
            guard pos+8<=bytes.count else { throw ImagingError.invalidPayload }
            let t=tag(pos)
            var valueStart:Int, length:Int
            if explicit {
                let vr=String(bytes:bytes[(pos+4)..<(pos+6)],encoding:.ascii) ?? ""
                guard vr.count==2,vr.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
                    throw ImagingError.invalidHeader("invalid explicit VR")
                }
                if longVRs.contains(vr) {
                    guard pos+12<=bytes.count else { throw ImagingError.invalidPayload }
                    valueStart=pos+12;length=Int(u32(pos+8))
                } else {
                    valueStart=pos+8;length=Int(u16(pos+6))
                }
            } else {
                valueStart=pos+8;length=Int(u32(pos+4))
            }
            guard length != Int(UInt32.max),length>=0,length<=bytes.count-valueStart else {
                throw ImagingError.unsupported("undefined-length SQ/encapsulated element or truncated element")
            }
            pos=valueStart+length
            return (t,valueStart,length)
        }
        while pos+8<=bytes.count, u16(pos)==0x0002 {
            let e=try parseElement(explicit:true)
            if e.tag==0x00020010 {
                transferSyntax=String(decoding:bytes[e.valueStart..<(e.valueStart+e.valueLength)],as:UTF8.self)
                    .trimmingCharacters(in:.whitespacesAndNewlines.union(.controlCharacters))
            }
        }
        guard let ts=transferSyntax else { throw ImagingError.invalidHeader("missing Transfer Syntax UID") }
        let explicit:Bool
        switch ts {
        case "1.2.840.10008.1.2.1", "1.2.840.10008.1.2.5":explicit=true
        case "1.2.840.10008.1.2":explicit=false
        default:throw ImagingError.unsupported("transfer syntax \(ts); only uncompressed Little Endian supported")
        }
        var pixelData:[UInt8]?
        while pos+8<=bytes.count {
            // Encapsulated RLE uses undefined-length Pixel Data, which cannot
            // be parsed as a normal explicit-VR element.
            if tag(pos)==0x7FE00010 && ts=="1.2.840.10008.1.2.5" {
                guard pos+12<=bytes.count,
                      (String(bytes:bytes[(pos+4)..<(pos+6)],encoding:.ascii)=="OB" ||
                       String(bytes:bytes[(pos+4)..<(pos+6)],encoding:.ascii)=="OW"),
                      u32(pos+8)==UInt32.max else { throw ImagingError.invalidPayload }
                pos += 12
                func readItem() throws -> [UInt8] {
                    guard pos+8<=bytes.count, tag(pos)==0xFFFEE000 else { throw ImagingError.invalidPayload }
                    let length=Int(u32(pos+4))
                    guard length <= bytes.count-pos-8 else { throw ImagingError.invalidPayload }
                    pos += 8
                    let item=Array(bytes[pos..<(pos+length)]);pos += length
                    return item
                }
                let offsets=try readItem() // Basic Offset Table, not image data.
                guard offsets.isEmpty || (offsets.count==4 && offsets.allSatisfy({ $0==0 })) else {
                    throw ImagingError.unsupported("multi-frame or unusual RLE basic offset table")
                }
                var payload=[UInt8]()
                while pos+8<=bytes.count && tag(pos)==0xFFFEE000 {
                    let part=try readItem()
                    guard part.count <= 20_000_000-payload.count else { throw ImagingError.tooLarge }
                    payload += part
                }
                guard pos+8<=bytes.count,tag(pos)==0xFFFEE0DD,u32(pos+4)==0,
                      !payload.isEmpty else { throw ImagingError.invalidPayload }
                pixelData=payload
                break
            }
            let e=try parseElement(explicit:explicit)
            if e.tag==0x7FE00010 {
                pixelData=Array(bytes[e.valueStart..<(e.valueStart+e.valueLength)])
                break
            }
            if desired.contains(e.tag) {
                fields[e.tag]=Array(bytes[e.valueStart..<(e.valueStart+e.valueLength)])
            }
        }
        func value(_ tag:UInt32)->[UInt8]? { fields[tag] }
        func ascii(_ tag:UInt32)->String? {
            guard let b=value(tag) else { return nil }
            return String(decoding:b,as:UTF8.self)
                .trimmingCharacters(in:.whitespacesAndNewlines.union(.controlCharacters))
        }
        func us(_ tag:UInt32)->Int? {
            guard let bytes=value(tag),bytes.count>=2 else { return nil }
            return Int(UInt16(bytes[0]) | (UInt16(bytes[1])<<8))
        }
        func ds(_ tag:UInt32,count:Int)->[Double]? {
            guard let text=ascii(tag) else { return nil }
            let parts=text.split(separator:"\\",omittingEmptySubsequences:false)
            guard parts.count==count else { return nil }
            let numbers=parts.compactMap { Double($0.trimmingCharacters(in:.whitespaces)) }
            return numbers.count==count && numbers.allSatisfy(\.isFinite) ? numbers : nil
        }
        guard let uid=ascii(0x0020000E),!uid.isEmpty,
              let rows=us(0x00280010),let cols=us(0x00280011),rows>1,cols>1,
              let spacing=ds(0x00280030,count:2),spacing.allSatisfy({ $0>0 }),
              let orientation=ds(0x00200037,count:6),
              let position=ds(0x00200032,count:3),
              let bitAllocated=us(0x00280100),let bitStored=us(0x00280101),
              let representation=us(0x00280103),let highBit=us(0x00280102),
              let channels=us(0x00280002),channels==1,
              let image=pixelData else {
            throw ImagingError.invalidHeader("missing conventional MR pixel or geometry attributes")
        }
        guard bitAllocated==8 || bitAllocated==16,bitStored>0,bitStored<=bitAllocated,
              highBit==bitStored-1,(representation==0 || representation==1) else {
            throw ImagingError.unsupported("pixel bit packing or representation")
        }
        guard ascii(0x00280004)=="MONOCHROME2" else {
            throw ImagingError.unsupported("only MONOCHROME2 grayscale is currently supported")
        }
        guard Int(ascii(0x00280008) ?? "1")==1 else {
            throw ImagingError.unsupported("multiframe and enhanced MRI are not supported")
        }
        let count=rows*cols,bytesPerVoxel=bitAllocated/8
        guard count<=4_000_000 else { throw ImagingError.tooLarge }
        let decoded:[UInt8]
        if ts=="1.2.840.10008.1.2.5" {
            decoded=try DicomRLEDecoder.decode(Data(image),pixelCount:count,bitsAllocated:bitAllocated)
        } else {
            guard image.count>=count*bytesPerVoxel else { throw ImagingError.invalidPayload }
            decoded=image
        }
        let slope=Double(ascii(0x00281053) ?? "1") ?? 1
        let intercept=Double(ascii(0x00281052) ?? "0") ?? 0
        guard slope.isFinite,intercept.isFinite else { throw ImagingError.invalidHeader("invalid rescale slope/intercept") }
        let mask=(UInt32(1)<<bitStored)-1
        let signBit=UInt32(1)<<(bitStored-1)
        var voxels=[Float](repeating:0,count:count)
        for i in 0..<count {
            let raw:UInt32
            if bitAllocated==8 { raw=UInt32(decoded[i]) }
            else { raw=UInt32(decoded[i*2]) | (UInt32(decoded[i*2+1])<<8) }
            let stored=raw & mask
            let signed:Double
            if representation==1 && (stored & signBit) != 0 {
                signed=Double(Int64(stored)-Int64(UInt32(1)<<bitStored))
            } else { signed=Double(stored) }
            let scaled=signed*slope+intercept
            guard scaled.isFinite, abs(scaled)<=Double(Float.greatestFiniteMagnitude) else {
                throw ImagingError.invalidPayload
            }
            voxels[i]=Float(scaled)
        }
        return Slice(seriesUID:uid,columns:cols,rows:rows,
                     rowSpacingMm:spacing[0],columnSpacingMm:spacing[1],
                     rowDirectionLPS:Point3(orientation[0],orientation[1],orientation[2]),
                     columnDirectionLPS:Point3(orientation[3],orientation[4],orientation[5]),
                     positionLPS:Point3(position[0],position[1],position[2]),pixels:voxels)
    }
}
