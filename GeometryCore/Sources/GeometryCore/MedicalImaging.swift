import Foundation

// Research imaging core: values and geometry are deliberately independent of UIKit/ARKit.
// CANONICAL COORDINATES: +X right, +Y superior, +Z anterior, in millimeters.
// This is not the standard NIfTI RAS axis order (+X right, +Y anterior, +Z superior).

public enum ImagingError: Error, LocalizedError, Sendable {
    case invalidHeader(String)
    case unsupported(String)
    case tooLarge
    case invalidAffine
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case let .invalidHeader(s): return "Invalid imaging header: \(s)"
        case let .unsupported(s): return "Unsupported imaging input: \(s)"
        case .tooLarge: return "Volume exceeds the research prototype's memory limits."
        case .invalidAffine: return "Missing, ambiguous or non-invertible physical image orientation."
        case .invalidPayload: return "Volume payload is truncated or invalid."
        }
    }
}

public struct VoxelAffine: Sendable, Equatable {
    public var originMm: Point3
    public var iMm: Point3
    public var jMm: Point3
    public var kMm: Point3

    public init(originMm: Point3, iMm: Point3, jMm: Point3, kMm: Point3) throws {
        self.originMm = originMm
        self.iMm = iMm
        self.jMm = jMm
        self.kMm = kMm
        guard [originMm,iMm,jMm,kMm].allSatisfy(\.allFinite),
              abs(Self.dot(iMm, Self.cross(jMm,kMm))) > 1e-6 else {
            throw ImagingError.invalidAffine
        }
    }

    public func point(i: Double, j: Double, k: Double) -> Point3 {
        originMm + iMm * i + jMm * j + kMm * k
    }

    public func index(of worldMm: Point3) -> Point3 {
        let v = worldMm - originMm
        let determinant = Self.dot(iMm, Self.cross(jMm,kMm))
        return Point3(Self.dot(v, Self.cross(jMm,kMm))/determinant,
                      Self.dot(v, Self.cross(kMm,iMm))/determinant,
                      Self.dot(v, Self.cross(iMm,jMm))/determinant)
    }

    private static func dot(_ a: Point3, _ b: Point3) -> Double {
        a.x*b.x + a.y*b.y + a.z*b.z
    }
    private static func cross(_ a: Point3, _ b: Point3) -> Point3 {
        Point3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x)
    }
}

public struct VolumeBounds: Sendable {
    public let minimum: Point3
    public let maximum: Point3
    public var center: Point3 { (minimum+maximum)*0.5 }
}

public struct VoxelVolume: Sendable {
    public let dimensions: [Int]
    public let affine: VoxelAffine
    public let voxels: [Float]
    public let description: String
    public let isSynthetic: Bool

    public init(dimensions: [Int], affine: VoxelAffine, voxels: [Float],
                description: String, isSynthetic: Bool = false) throws {
        guard dimensions.count == 3, dimensions.allSatisfy({ $0 > 1 && $0 <= 2048 }),
              dimensions[0] * dimensions[1] * dimensions[2] == voxels.count else {
            throw ImagingError.invalidPayload
        }
        guard voxels.count <= 32_000_000 else { throw ImagingError.tooLarge }
        self.dimensions=dimensions
        self.affine=affine
        self.voxels=voxels
        self.description=description
        self.isSynthetic=isSynthetic
    }

    public var bounds: VolumeBounds {
        let nx=Double(dimensions[0]-1), ny=Double(dimensions[1]-1), nz=Double(dimensions[2]-1)
        var minPoint=Point3(.infinity,.infinity,.infinity)
        var maxPoint=Point3(-.infinity,-.infinity,-.infinity)
        for x in [0.0,nx] { for y in [0.0,ny] { for z in [0.0,nz] {
            let p=affine.point(i:x,j:y,k:z)
            for axis in 0..<3 {
                minPoint[axis]=min(minPoint[axis],p[axis])
                maxPoint[axis]=max(maxPoint[axis],p[axis])
            }
        }}}
        return VolumeBounds(minimum:minPoint,maximum:maxPoint)
    }

    public func value(i: Int,j: Int,k: Int) -> Float? {
        guard i>=0,j>=0,k>=0,i<dimensions[0],j<dimensions[1],k<dimensions[2] else { return nil }
        return voxels[(k*dimensions[1]+j)*dimensions[0]+i]
    }

    public func nearest(at point: Point3) -> Float? {
        let c=affine.index(of:point)
        guard c.allFinite else { return nil }
        return value(i:Int(c.x.rounded()),j:Int(c.y.rounded()),k:Int(c.z.rounded()))
    }

    public func trilinear(at point: Point3) -> Float? {
        let p=affine.index(of:point)
        guard p.allFinite,
              p.x>=0,p.y>=0,p.z>=0,
              p.x<=Double(dimensions[0]-1),p.y<=Double(dimensions[1]-1),p.z<=Double(dimensions[2]-1) else { return nil }
        let x0=Int(floor(p.x)), y0=Int(floor(p.y)), z0=Int(floor(p.z))
        let x1=min(x0+1,dimensions[0]-1), y1=min(y0+1,dimensions[1]-1), z1=min(z0+1,dimensions[2]-1)
        let u=Float(p.x-Double(x0)), v=Float(p.y-Double(y0)), w=Float(p.z-Double(z0))
        func val(_ x:Int,_ y:Int,_ z:Int)->Float { voxels[(z*dimensions[1]+y)*dimensions[0]+x] }
        let a0=val(x0,y0,z0)*(1-u)+val(x1,y0,z0)*u
        let a1=val(x0,y1,z0)*(1-u)+val(x1,y1,z0)*u
        let b0=val(x0,y0,z1)*(1-u)+val(x1,y0,z1)*u
        let b1=val(x0,y1,z1)*(1-u)+val(x1,y1,z1)*u
        return (a0*(1-v)+a1*v)*(1-w)+(b0*(1-v)+b1*v)*w
    }

    public func defaultWindow() -> ClosedRange<Float> {
        let strideAmount=max(1,voxels.count/100_000)
        let sorted=Swift.stride(from:0,to:voxels.count,by:strideAmount)
            .map { voxels[$0] }.filter(\.isFinite).sorted()
        guard let first=sorted.first,let last=sorted.last else { return 0...1 }
        let low=sorted[Int(Double(sorted.count-1)*0.02)]
        let high=sorted[Int(Double(sorted.count-1)*0.98)]
        if high-low > 1e-6 { return low...high }
        if last-first > 1e-6 { return first...last }
        return first...(first+1)
    }

    public static func syntheticDemo() -> VoxelVolume {
        let n=96
        let affine=try! VoxelAffine(originMm:Point3(-95,-95,-95),
                                      iMm:Point3(2,0,0),jMm:Point3(0,0,2),kMm:Point3(0,2,0))
        var v=[Float](repeating:0,count:n*n*n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p=affine.point(i:Double(i),j:Double(j),k:Double(k))
            let r=(p.x/72)*(p.x/72)+(p.y/84)*(p.y/84)+(p.z/78)*(p.z/78)
            let ventA=pow((p.x-12)/9,2)+pow((p.y-4)/18,2)+pow((p.z+1)/12,2)
            let ventB=pow((p.x+12)/9,2)+pow((p.y-4)/18,2)+pow((p.z+1)/12,2)
            let shell = r < 1.10 && r > 0.92
            let value:Float = r > 1.1 ? 0 : (shell ? 180 : (ventA<1 || ventB<1 ? 25 : 100))
            v[(k*n+j)*n+i]=value
        }}}
        return try! VoxelVolume(dimensions:[n,n,n],affine:affine,voxels:v,
                                description:"SYNTHETIC phantom (not patient MRI)",isSynthetic:true)
    }
}

public enum ImagingPlane: String, CaseIterable, Sendable {
    case axial = "Axial"
    case coronal = "Coronal"
    case sagittal = "Sagittal"

    public var horizontalAxis: Int { self == .sagittal ? 2 : 0 }
    public var verticalAxis: Int { self == .axial ? 2 : 1 }
    public var fixedAxis: Int { self == .axial ? 1 : (self == .coronal ? 2 : 0) }
}

/// Square field-of-view with identical mm per pixel horizontally and vertically.
public struct SliceFrame: Sendable {
    public let plane: ImagingPlane
    public let centerMm: Point3
    public let horizontalCenterMm: Double
    public let verticalCenterMm: Double
    public let sideMm: Double

    public init(plane: ImagingPlane, bounds: VolumeBounds, cursor: Point3) {
        self.plane=plane
        self.centerMm=cursor
        let h=plane.horizontalAxis, v=plane.verticalAxis
        horizontalCenterMm=(bounds.minimum[h]+bounds.maximum[h])*0.5
        verticalCenterMm=(bounds.minimum[v]+bounds.maximum[v])*0.5
        sideMm=max(1,max(bounds.maximum[h]-bounds.minimum[h],
                         bounds.maximum[v]-bounds.minimum[v])*1.05)
    }

    public func world(u: Double, v: Double) -> Point3 {
        var p=centerMm
        p[plane.horizontalAxis]=horizontalCenterMm+(u-0.5)*sideMm
        p[plane.verticalAxis]=verticalCenterMm+(0.5-v)*sideMm
        return p
    }
    public func uv(for point: Point3) -> (u: Double,v: Double) {
        (0.5+(point[plane.horizontalAxis]-horizontalCenterMm)/sideMm,
         0.5-(point[plane.verticalAxis]-verticalCenterMm)/sideMm)
    }
}

public struct SliceRaster: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public let frame: SliceFrame
}

public enum SliceRenderer {
    public static func render(volume: VoxelVolume, mask: VoxelVolume?,
                              plane: ImagingPlane, cursor: Point3,
                              window: ClosedRange<Float>, width: Int = 192,
                              height: Int = 192) -> SliceRaster {
        let w=max(1,min(width,1024)), h=max(1,min(height,1024))
        let frame=SliceFrame(plane:plane,bounds:volume.bounds,cursor:cursor)
        let low=window.lowerBound, span=max(1e-5,window.upperBound-low)
        var rgba=[UInt8](repeating:0,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let pt=frame.world(u:(Double(x)+0.5)/Double(w),v:(Double(y)+0.5)/Double(h))
            let pix=(y*w+x)*4
            let value=volume.trilinear(at:pt)
            let grey=UInt8((max(Float(0),min(Float(1),((value ?? low)-low)/span))*255).rounded())
            if value == nil { rgba[pix]=0;rgba[pix+1]=0;rgba[pix+2]=0 }
            else if (mask?.nearest(at:pt) ?? 0) > 0.5 {
                rgba[pix]=UInt8(Float(grey)*0.35)
                rgba[pix+1]=UInt8(min(255,Float(grey)*0.6+110))
                rgba[pix+2]=UInt8(min(255,Float(grey)*0.5+145))
            } else { rgba[pix]=grey;rgba[pix+1]=grey;rgba[pix+2]=grey }
            rgba[pix+3]=255
        }}
        return SliceRaster(width:w,height:h,rgba:rgba,frame:frame)
    }
}

public struct MaskIntersection: Sendable {
    public let sampledPoints: Int
    public let pointsInsideMask: Int
    public let firstIntersectionDepthMm: Double?
    public let anyOutOfVolume: Bool
}

/// This is a sampled geometric overlap indicator, NOT a vessel-clearance or safety classifier.
public enum TrajectoryMaskSampler {
    public static func analyze(_ path: StudyTrajectory, mask: VoxelVolume,
                               referenceVolume: VoxelVolume,
                               spacingMm: Double = 1) -> MaskIntersection {
        guard path.lengthMm.isFinite, path.lengthMm>=0 else {
            return MaskIntersection(sampledPoints:0,pointsInsideMask:0,
                                    firstIntersectionDepthMm:nil,anyOutOfVolume:true)
        }
        let n=max(1,Int(min(10000,ceil(path.lengthMm/max(0.1,spacingMm)))))
        var count=0,first:Double?=nil,outside=false
        for i in 0...n {
            let d=path.lengthMm*Double(i)/Double(n)
            let p=path.atDepth(d)
            if referenceVolume.nearest(at:p)==nil { outside=true }
            if (mask.nearest(at:p) ?? 0)>0.5 {
                count+=1
                if first==nil { first=d }
            }
        }
        return MaskIntersection(sampledPoints:n+1,pointsInsideMask:count,
                                firstIntersectionDepthMm:first,anyOutOfVolume:outside)
    }
}
