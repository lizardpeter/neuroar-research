import Foundation
import ARKit
import Vision
import GeometryCore
import ImageIO

/// Natural, marker-free features acquired from the REAR camera through Vision,
/// paired with high-confidence LiDAR samples in the same ARFrame.
/// Detection, not patient identity recognition or validated MRI registration.
struct NaturalHeadObservation {
    let timestamp: TimeInterval
    let features: [NaturalFacePoint]
    let faceCloudMeters: [Point3]
    let detectionConfidence: Float
}

final class NaturalHeadTracker {
    private let queue = DispatchQueue(label: "neuroar.natural-head-vision", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = false
    private var lastSubmitted: TimeInterval = -1

    func submit(frame: ARFrame, completion: @escaping (NaturalHeadObservation?) -> Void) {
        lock.lock()
        if inFlight || (lastSubmitted >= 0 && frame.timestamp - lastSubmitted < 0.16) {
            lock.unlock()
            return
        }
        inFlight = true
        lastSubmitted = frame.timestamp
        lock.unlock()
        queue.async { [weak self] in
            let observation = Self.observe(frame: frame)
            self?.lock.lock()
            self?.inFlight = false
            self?.lock.unlock()
            DispatchQueue.main.async { completion(observation) }
        }
    }

    private static func observe(frame: ARFrame) -> NaturalHeadObservation? {
        guard let depth = frame.sceneDepth else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        // iPhone target supports portrait UI. The rear sensor buffer remains
        // landscape: orient it for Vision, then map Vision positions back to
        // the unrotated camera/depth pixel grid below.
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage,
                                            orientation: .right, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let faces = request.results, faces.count == 1, let face = faces.first,
              face.confidence > 0.6, face.boundingBox.width > 0.12,
              face.boundingBox.height > 0.12, let landmarks = face.landmarks else { return nil }
        let regions: [(NaturalFaceFeature, VNFaceLandmarkRegion2D?)] = [
            (.leftEyeCenter, landmarks.leftEye),
            (.rightEyeCenter, landmarks.rightEye),
            (.noseTip, landmarks.nose),
            (.mouthCenter, landmarks.outerLips)
        ]
        let depthMap = depth.depthMap
        let w = CVPixelBufferGetWidth(depthMap), h = CVPixelBufferGetHeight(depthMap)
        let imageW = Double(CVPixelBufferGetWidth(frame.capturedImage))
        let imageH = Double(CVPixelBufferGetHeight(frame.capturedImage))
        guard w > 0, h > 0, imageW > 0, imageH > 0 else { return nil }
        let k = frame.camera.intrinsics
        let fx = Double(k.columns.0.x), fy = Double(k.columns.1.y)
        let cx = Double(k.columns.2.x), cy = Double(k.columns.2.y)
        guard fx > 0, fy > 0 else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let confidence = depth.confidenceMap
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        let confidenceRaw = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confW = confidence.map { CVPixelBufferGetWidth($0) } ?? w
        let confH = confidence.map { CVPixelBufferGetHeight($0) } ?? h
        let confStride = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // The Vision image is rotated clockwise from the raw ARKit buffer.
        // In Vision coordinates Y rises upward. Convert these normalized
        // oriented coordinates to raw normalized bottom-left sensor coordinates.
        func rawSensor(_ x: Double, _ y: Double) -> (Double, Double) {
            (1 - y, x)
        }
        func readDepth(pixelX: Int, pixelY: Int) -> Double? {
            guard pixelX >= 0, pixelX < w, pixelY >= 0, pixelY < h else { return nil }
            let sample = raw.advanced(by: pixelY * CVPixelBufferGetBytesPerRow(depthMap))
                .assumingMemoryBound(to: Float32.self)[pixelX]
            let z = Double(sample)
            guard z.isFinite, (0.18...1.20).contains(z) else { return nil }
            if let confidenceRaw {
                let confX = min(confW - 1, pixelX * confW / w)
                let confY = min(confH - 1, pixelY * confH / h)
                let score = confidenceRaw.advanced(by: confY * confStride)
                    .assumingMemoryBound(to: UInt8.self)[confX]
                guard score >= 2 else { return nil }
            }
            return z
        }
        func worldPoint(normalizedX: Double, normalizedYFromBottom: Double) -> Point3? {
            guard (0..<1).contains(normalizedX), (0..<1).contains(normalizedYFromBottom) else { return nil }
            let x = min(w - 1, Int(normalizedX * Double(w)))
            let y = min(h - 1, Int((1 - normalizedYFromBottom) * Double(h)))
            var neighborhood: [Double] = []
            for yy in max(0, y - 1)...min(h - 1, y + 1) {
                for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    if let z = readDepth(pixelX: xx, pixelY: yy) { neighborhood.append(z) }
                }
            }
            guard neighborhood.count >= 4 else { return nil }
            neighborhood.sort()
            let z = neighborhood[neighborhood.count / 2]
            let imageX = normalizedX * imageW
            let imageY = (1 - normalizedYFromBottom) * imageH
            let camera = SIMD4<Float>(Float((imageX - cx) * z / fx),
                                        Float(-(imageY - cy) * z / fy), Float(-z), 1)
            let world = frame.camera.transform * camera
            return Point3(Double(world.x), Double(world.y), Double(world.z))
        }
        var points: [NaturalFacePoint] = []
        for (feature, region) in regions {
            guard let region, !region.normalizedPoints.isEmpty else { continue }
            let normalized = region.normalizedPoints
            // Eyes and mouth use the polygon center. Nose uses the nearest
            // high-confidence point to approximate the visible nose prominence.
            let locations = normalized.map { position -> (Double, Double) in
                let visionX = Double(face.boundingBox.minX + position.x * face.boundingBox.width)
                let visionY = Double(face.boundingBox.minY + position.y * face.boundingBox.height)
                return rawSensor(visionX, visionY)
            }
            let candidate: Point3?
            if feature == .noseTip {
                let options = locations.compactMap { worldPoint(normalizedX: $0.0, normalizedYFromBottom: $0.1) }
                let cameraOrigin = frame.camera.transform.columns.3
                let cameraPoint = Point3(Double(cameraOrigin.x), Double(cameraOrigin.y), Double(cameraOrigin.z))
                candidate = options.min { ($0 - cameraPoint).norm < ($1 - cameraPoint).norm }
            } else {
                let meanX = locations.reduce(0.0) { $0 + $1.0 } / Double(locations.count)
                let meanY = locations.reduce(0.0) { $0 + $1.1 } / Double(locations.count)
                candidate = worldPoint(normalizedX: meanX, normalizedYFromBottom: meanY)
            }
            if let candidate { points.append(.init(feature: feature, worldMeters: candidate)) }
        }
        guard points.count >= 3 else { return nil }
        // A face-relative LiDAR patch is used for independent *surface* checks;
        // it is never considered an anatomical tissue segmentation.
        var cloud = [Point3]()
        let rect = face.boundingBox.insetBy(dx: face.boundingBox.width * 0.08,
                                             dy: face.boundingBox.height * 0.08)
        let rawRect = CGRect(x: 1 - rect.maxY, y: rect.minX,
                             width: rect.height, height: rect.width)
        let dx = max(2, Int(sqrt(Double(w * h) / 950.0)))
        let lowX = max(0, Int(Double(w) * Double(rawRect.minX)))
        let highX = min(w, Int(Double(w) * Double(rawRect.maxX)))
        let lowY = max(0, Int(Double(h) * Double(1 - rawRect.maxY)))
        let highY = min(h, Int(Double(h) * Double(1 - rawRect.minY)))
        if lowX < highX, lowY < highY {
            let nose = points.first(where: { $0.feature == .noseTip })?.worldMeters
            let cameraOrigin = frame.camera.transform.columns.3
            let cameraPoint = Point3(Double(cameraOrigin.x), Double(cameraOrigin.y), Double(cameraOrigin.z))
            for y in stride(from: lowY, to: highY, by: dx) {
                for x in stride(from: lowX, to: highX, by: dx) {
                    guard let z = readDepth(pixelX: x, pixelY: y) else { continue }
                    let normalizedX = (Double(x) + 0.5) / Double(w)
                    let normalizedY = 1 - (Double(y) + 0.5) / Double(h)
                    let imgX = normalizedX * imageW, imgY = (1 - normalizedY) * imageH
                    let camera = SIMD4<Float>(Float((imgX - cx) * z / fx),
                                                Float(-(imgY - cy) * z / fy), Float(-z), 1)
                    let world = frame.camera.transform * camera
                    let p = Point3(Double(world.x), Double(world.y), Double(world.z))
                    if p.allFinite && (nose == nil || abs((p - cameraPoint).norm - (nose! - cameraPoint).norm) < 0.12) {
                        cloud.append(p)
                    }
                }
            }
        }
        return NaturalHeadObservation(timestamp: frame.timestamp, features: points,
                                      faceCloudMeters: cloud, detectionConfidence: face.confidence)
    }
}
