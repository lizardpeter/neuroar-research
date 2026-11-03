import ARKit
import UIKit
import GeometryCore

/// Returns a *single* physical LiDAR sample in ARKit world meters.
/// Calibration/orientation behavior must be checked on physical devices.
enum DepthUnprojector {
    enum SampleError: Error, LocalizedError {
        case noDepth, invalidPoint, lowConfidence, outOfRange, inconsistentNeighborhood
        var errorDescription: String? {
            switch self {
            case .noDepth: "No LiDAR depth is available in this frame."
            case .invalidPoint: "Point is outside the camera image."
            case .lowConfidence: "LiDAR reading is low confidence. Choose a better-lit surface."
            case .outOfRange: "Depth reading is unavailable or outside the demo capture range."
            case .inconsistentNeighborhood: "LiDAR samples disagree at this point. Tap a stable, well-lit surface away from depth edges."
            }
        }
    }

    static func worldPoint(at screenPoint: CGPoint, viewportSize: CGSize,
                           orientation: UIInterfaceOrientation, frame: ARFrame) throws -> Point3 {
        guard let depth = frame.sceneDepth else { throw SampleError.noDepth }
        guard viewportSize.width > 0 && viewportSize.height > 0 else { throw SampleError.invalidPoint }
        let screen = CGPoint(x: screenPoint.x/viewportSize.width,
                             y: screenPoint.y/viewportSize.height)
        let normalized = screen.applying(frame.displayTransform(for: orientation,
                                                               viewportSize: viewportSize).inverted())
        guard normalized.x >= 0, normalized.x < 1, normalized.y >= 0, normalized.y < 1 else {
            throw SampleError.invalidPoint
        }
        let map = depth.depthMap
        let dw = CVPixelBufferGetWidth(map), dh = CVPixelBufferGetHeight(map)
        let col = min(dw-1, Int(normalized.x*CGFloat(dw)))
        let row = min(dh-1, Int(normalized.y*CGFloat(dh)))
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { throw SampleError.noDepth }
        let confidence=depth.confidenceMap
        if let confidence { CVPixelBufferLockBaseAddress(confidence,.readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence,.readOnly) } }
        let confidenceBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let cw = confidence.map { CVPixelBufferGetWidth($0) } ?? dw
        let ch = confidence.map { CVPixelBufferGetHeight($0) } ?? dh
        let cbpr = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        var observations:[DepthObservation]=[]
        for yy in max(0,row-1)...min(dh-1,row+1) {
            for xx in max(0,col-1)...min(dw-1,col+1) {
                let rowBuffer=base.advanced(by:yy*CVPixelBufferGetBytesPerRow(map))
                let d=rowBuffer.assumingMemoryBound(to:Float32.self)[xx]
                let conf:UInt8
                if let confidenceBase {
                    let cx=min(cw-1,Int((Double(xx)+0.5)*Double(cw)/Double(dw)))
                    let cy=min(ch-1,Int((Double(yy)+0.5)*Double(ch)/Double(dh)))
                    conf=confidenceBase.advanced(by:cy*cbpr)
                        .assumingMemoryBound(to:UInt8.self)[cx]
                } else { conf=1 }
                observations.append(DepthObservation(meters:d,confidence:conf))
            }
        }
        guard let estimate=DepthStatistics.estimate(observations) else {
            throw SampleError.inconsistentNeighborhood
        }
        let distance=Double(estimate.meters)

        let width = Double(CVPixelBufferGetWidth(frame.capturedImage))
        let height = Double(CVPixelBufferGetHeight(frame.capturedImage))
        let pixelX = Double(normalized.x)*width
        let pixelY = Double(normalized.y)*height
        let K = frame.camera.intrinsics
        let fx=Double(K.columns.0.x), fy=Double(K.columns.1.y)
        let principalX=Double(K.columns.2.x), principalY=Double(K.columns.2.y)
        guard fx > 0 && fy > 0 else { throw SampleError.invalidPoint }
        // ARKit camera: X right, Y up, forward is -Z.
        let cameraPoint = SIMD4<Float>(Float((pixelX-principalX)*distance/fx),
                                       Float(-(pixelY-principalY)*distance/fy),
                                       Float(-distance),1)
        let world = frame.camera.transform * cameraPoint
        return Point3(Double(world.x),Double(world.y),Double(world.z))
    }
}
