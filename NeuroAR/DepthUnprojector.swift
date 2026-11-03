import ARKit
import UIKit
import GeometryCore

/// Returns a *single* physical LiDAR sample in ARKit world meters.
/// Calibration/orientation behavior must be checked on physical devices.
enum DepthUnprojector {
    enum SampleError: Error, LocalizedError {
        case noDepth, invalidPoint, lowConfidence, outOfRange
        var errorDescription: String? {
            switch self {
            case .noDepth: "No LiDAR depth is available in this frame."
            case .invalidPoint: "Point is outside the camera image."
            case .lowConfidence: "LiDAR reading is low confidence. Choose a better-lit surface."
            case .outOfRange: "Depth reading is unavailable or outside the demo capture range."
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
        let rowBase = base.advanced(by: row*CVPixelBufferGetBytesPerRow(map))
        let distance = Double(rowBase.assumingMemoryBound(to: Float32.self)[col])
        guard distance.isFinite, distance >= 0.15, distance <= 2.5 else { throw SampleError.outOfRange }

        if let confidence = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            guard let cbase = CVPixelBufferGetBaseAddress(confidence) else { throw SampleError.lowConfidence }
            let cx = min(CVPixelBufferGetWidth(confidence)-1,
                         Int(normalized.x*CGFloat(CVPixelBufferGetWidth(confidence))))
            let cy = min(CVPixelBufferGetHeight(confidence)-1,
                         Int(normalized.y*CGFloat(CVPixelBufferGetHeight(confidence))))
            let confidenceValue = cbase.advanced(by: cy*CVPixelBufferGetBytesPerRow(confidence))
                .assumingMemoryBound(to: UInt8.self)[cx]
            guard confidenceValue >= 1 else { throw SampleError.lowConfidence }
        }

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
