import Foundation
import ARKit
import UIKit
import GeometryCore

/// Single-frame depth cloud using calibrated ARKit camera intrinsics and pose.
/// Crops a central camera region and a landmark-centred 3D neighborhood to
/// reduce unrelated background; it does NOT identify or segment the scalp.
enum DepthPointCloud {
    static func capture(frame: ARFrame, around landmarkPoints: [Point3], radiusMeters: Double = 0.18) throws -> [Point3] {
        guard let depth=frame.sceneDepth else { throw DepthUnprojector.SampleError.noDepth }
        guard landmarkPoints.count >= 3 && landmarkPoints.allSatisfy(\.allFinite) else {
            throw SurfaceRegistrationError.invalidInput
        }
        let mean=landmarkPoints.reduce(Point3(0,0,0),+)*(1.0/Double(landmarkPoints.count))
        let map=depth.depthMap
        let w=CVPixelBufferGetWidth(map),h=CVPixelBufferGetHeight(map)
        guard w>0,h>0 else { throw DepthUnprojector.SampleError.noDepth }
        let imageWidth=Double(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight=Double(CVPixelBufferGetHeight(frame.capturedImage))
        let k=frame.camera.intrinsics
        let fx=Double(k.columns.0.x)*Double(w)/imageWidth
        let fy=Double(k.columns.1.y)*Double(h)/imageHeight
        let cx=Double(k.columns.2.x)*Double(w)/imageWidth
        let cy=Double(k.columns.2.y)*Double(h)/imageHeight
        guard fx>0,fy>0 else { throw DepthUnprojector.SampleError.invalidPoint }
        let confidence=depth.confidenceMap
        CVPixelBufferLockBaseAddress(map,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map,.readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence,.readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence,.readOnly) } }
        guard let raw=CVPixelBufferGetBaseAddress(map) else { throw DepthUnprojector.SampleError.noDepth }
        let confRaw=confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let cw=confidence.map { CVPixelBufferGetWidth($0) } ?? w
        let ch=confidence.map { CVPixelBufferGetHeight($0) } ?? h
        let cStride=confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let step=max(2,Int(sqrt(Double(w*h)/1700.0)))
        var points=[Point3]()
        let matrix=frame.camera.transform
        for y in stride(from:Int(Double(h)*0.12),to:Int(Double(h)*0.88),by:step) {
            let row=raw.advanced(by:y*CVPixelBufferGetBytesPerRow(map))
                .assumingMemoryBound(to:Float32.self)
            for x in stride(from:Int(Double(w)*0.15),to:Int(Double(w)*0.85),by:step) {
                let z=Double(row[x])
                guard z.isFinite,(0.15...1.3).contains(z) else { continue }
                if let confRaw {
                    let px=min(cw-1,(x*cw)/w),py=min(ch-1,(y*ch)/h)
                    let confidence=confRaw.advanced(by:py*cStride)
                        .assumingMemoryBound(to:UInt8.self)[px]
                    guard confidence>=2 else { continue }
                }
                let camera=SIMD4<Float>(Float((Double(x)-cx)*z/fx),
                                         Float(-(Double(y)-cy)*z/fy),Float(-z),1)
                let world=matrix*camera
                let p=Point3(Double(world.x),Double(world.y),Double(world.z))
                if p.allFinite && (p-mean).norm < radiusMeters { points.append(p) }
            }
        }
        return points
    }
}
