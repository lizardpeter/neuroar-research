import Foundation

/// NIfTI-1 single-file .nii parser, standard uncompressed scalar 3-D volumes only.
/// Affine from sform when available, otherwise qform. Missing transforms are rejected.
/// Converts RAS (+R,+A,+S) to NeuroAR canonical (+R,+S,+A) explicitly.
public enum NiftiReader {
    public static func load(_ data: Data) throws -> VoxelVolume {
        guard data.count >= 352 else { throw ImagingError.invalidHeader("file shorter than 352-byte NIfTI-1 preamble") }
        guard data.count <= 550_000_000 else { throw ImagingError.tooLarge }
        let bytes=[UInt8](data.prefix(352))
        let little: Bool
        let headLE=UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        if headLE == 348 { little=true }
        else if headLE.byteSwapped == 348 { little=false }
        else { throw ImagingError.invalidHeader("sizeof_hdr must equal 348") }

        func u16(_ o:Int)->UInt16 {
            let a=UInt16(bytes[o]), b=UInt16(bytes[o+1]);return little ? a | (b<<8) : (a<<8) | b
        }
        func u32(_ o:Int)->UInt32 {
            let a=UInt32(u16(o)),b=UInt32(u16(o+2));return little ? a | (b<<16) : (a<<16) | b
        }
        func f32(_ o:Int)->Double { Double(Float(bitPattern:u32(o))) }
        func i16(_ o:Int)->Int { Int(Int16(bitPattern:u16(o))) }
        guard bytes[344]==110, bytes[345]==43, bytes[346]==49, bytes[347]==0 else {
            throw ImagingError.unsupported("NIfTI-1 .nii magic (n+1) is required; .hdr/.img and NIfTI-2 are unsupported")
        }
        let rank=i16(40)
        guard rank==3 || rank==4 else { throw ImagingError.unsupported("only 3-D scalar volumes supported") }
        let dimensions=(0..<3).map { i16(42+$0*2) }
        guard dimensions.allSatisfy({ $0>1 && $0<=2048 }) else { throw ImagingError.invalidHeader("invalid 3-D dimensions") }
        if rank==4 && i16(48) != 1 { throw ImagingError.unsupported("time series require explicit frame selection") }
        guard dimensions[0]*dimensions[1]*dimensions[2] <= 32_000_000 else { throw ImagingError.tooLarge }
        let code=i16(70), bits=i16(72)
        let channels: (Int,Int)
        switch code {
        case 2: channels=(1,8)        // UINT8
        case 4: channels=(2,16)       // INT16
        case 8: channels=(4,32)       // INT32
        case 16: channels=(4,32)      // FLOAT32
        case 64: channels=(8,64)      // FLOAT64
        case 256: channels=(1,8)      // INT8
        case 512: channels=(2,16)     // UINT16
        case 768: channels=(4,32)     // UINT32
        default: throw ImagingError.unsupported("NIfTI datatype \(code) (RGB/vector/complex unsupported)")
        }
        guard bits==channels.1 else { throw ImagingError.invalidHeader("datatype/bitpix mismatch") }
        let n=dimensions[0]*dimensions[1]*dimensions[2]
        let offset=f32(108)
        guard offset.isFinite,offset>=352,offset.rounded(.down)==offset,
              offset < Double(Int.max),Int(offset)<=data.count,
              n <= (data.count-Int(offset))/channels.0 else { throw ImagingError.invalidPayload }
        let slope=f32(112), intercept=f32(116)
        let useScale=slope.isFinite && slope != 0 && intercept.isFinite
        let scale=useScale ? slope : 1
        let shift=useScale ? intercept : 0
        let units=Int(bytes[123])&0x07
        let unitScale:Double
        switch units {
        case 1: unitScale=1000        // metres
        case 2: unitScale=1           // mm
        case 3: unitScale=0.001       // micrometres
        default: throw ImagingError.unsupported("spatial units must be explicitly specified")
        }
        func rasToCanonical(_ p:Point3)->Point3 { Point3(p.x,p.z,p.y)*unitScale }
        let sform=i16(254),qform=i16(252)
        let affine: VoxelAffine
        if sform>0 {
            let x=(0..<4).map { f32(280+$0*4) }
            let y=(0..<4).map { f32(296+$0*4) }
            let z=(0..<4).map { f32(312+$0*4) }
            affine=try VoxelAffine(
                originMm:rasToCanonical(Point3(x[3],y[3],z[3])),
                iMm:rasToCanonical(Point3(x[0],y[0],z[0])),
                jMm:rasToCanonical(Point3(x[1],y[1],z[1])),
                kMm:rasToCanonical(Point3(x[2],y[2],z[2])))
        } else if qform>0 {
            let b=f32(256),c=f32(260),d=f32(264)
            let a2=1-(b*b+c*c+d*d)
            guard a2 >= -0.001 else { throw ImagingError.invalidAffine }
            var qa=sqrt(max(a2,0)),qb=b,qc=c,qd=d
            if qa < 1e-7 {
                let length=sqrt(qb*qb+qc*qc+qd*qd)
                guard length>0 else { throw ImagingError.invalidAffine }
                qa=0;qb /= length;qc /= length;qd /= length
            }
            // NIfTI quaternion-based RAS rotation matrix.
            let r1=Point3(qa*qa+qb*qb-qc*qc-qd*qd,2*(qb*qc-qa*qd),2*(qb*qd+qa*qc))
            let r2=Point3(2*(qb*qc+qa*qd),qa*qa+qc*qc-qb*qb-qd*qd,2*(qc*qd-qa*qb))
            let r3=Point3(2*(qb*qd-qa*qc),2*(qc*qd+qa*qb),qa*qa+qd*qd-qc*qc-qb*qb)
            let spacing=(1...3).map { f32(76+$0*4) }
            guard spacing.allSatisfy({ $0.isFinite && $0>0 }) else { throw ImagingError.invalidAffine }
            let qfac=f32(76)<0 ? -1.0 : 1.0
            func column(_ col:Int)->Point3 { Point3(r1[col],r2[col],r3[col]) * (spacing[col] * (col==2 ? qfac : 1)) }
            affine=try VoxelAffine(originMm:rasToCanonical(Point3(f32(268),f32(272),f32(276))),
                                    iMm:rasToCanonical(column(0)),jMm:rasToCanonical(column(1)),
                                    kMm:rasToCanonical(column(2)))
        } else { throw ImagingError.invalidAffine }

        var values=[Float](repeating:0,count:n)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Void in
            let base=Int(offset)
            func word16(_ o:Int)->UInt16 {
                let x=raw[o],y=raw[o+1]
                return little ? UInt16(x)|(UInt16(y)<<8) : UInt16(y)|(UInt16(x)<<8)
            }
            func word32(_ o:Int)->UInt32 {
                let a=UInt32(word16(o)),b=UInt32(word16(o+2))
                return little ? a | (b<<16) : (a<<16) | b
            }
            for i in 0..<n {
                let at=base+i*channels.0
                let number:Double
                switch code {
                case 2: number=Double(Int(raw[at]))
                case 4: number=Double(Int16(bitPattern:word16(at)))
                case 8: number=Double(Int32(bitPattern:word32(at)))
                case 16: number=Double(Float(bitPattern:word32(at)))
                case 64:
                    let lo=UInt64(word32(at)),hi=UInt64(word32(at+4))
                    number=Double(bitPattern:little ? (lo | (hi<<32)) : ((lo<<32) | hi))
                case 256: number=Double(Int8(bitPattern:raw[at]))
                case 512: number=Double(word16(at))
                case 768: number=Double(word32(at))
                default: throw ImagingError.unsupported("datatype")
                }
                let scaled=number*scale+shift
                values[i]=scaled.isFinite ? Float(max(-Double(Float.greatestFiniteMagnitude), min(Double(Float.greatestFiniteMagnitude),scaled))) : 0
            }
        }
        return try VoxelVolume(dimensions:dimensions,affine:affine,voxels:values,
                               description:"NIfTI-1 · \(dimensions.map(String.init).joined(separator:"×")) · \(sform>0 ? "sform" : "qform")")
    }
}
