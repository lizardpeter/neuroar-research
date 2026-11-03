import Foundation
import ARKit
import Vision
import ImageIO
import CoreGraphics

/// Image-plane hand control, not world-space skeletal tracking.
/// Runs on a background queue, reuses the Vision request, rejects weak points,
/// and requires a stable pinch before emitting a manipulation delta.
final class VisionHandInput {
    enum Change {
        case none
        case translate(CGFloat,CGFloat)
        case transform(scale:CGFloat, twist:CGFloat, turn:CGFloat)
    }

    private struct Pinch {
        var center: CGPoint
        var closed: Bool
    }

    private let workQueue = DispatchQueue(label:"neuroar.research.hand-vision",
                                          qos:.userInitiated)
    private let request = VNDetectHumanHandPoseRequest()
    private var pending = false
    private var lastRequestTime: TimeInterval = -.infinity
    private var stableCount = 0
    private var lastMode = 0
    private var previousOne: CGPoint?
    private var previousTwo: (center:CGPoint,distance:CGFloat,angle:CGFloat)?
    private var previousSmoothed: [CGPoint] = []
    private var lastVisibleAt: TimeInterval = 0

    init() {
        request.maximumHandCount = 2
    }

    func reset() {
        previousOne = nil
        previousTwo = nil
        previousSmoothed.removeAll()
        lastMode = 0
        stableCount = 0
    }

    /// Called on the main ARSession delegate queue. Data processing never
    /// blocks it. At most one outstanding Vision request and ~8 per second.
    func process(frame: ARFrame,
                 isEnabled: Bool,
                 deliver: @escaping (Change, String) -> Void) {
        guard isEnabled else {
            reset()
            return
        }
        guard !pending, frame.timestamp - lastRequestTime >= 0.12 else { return }
        pending = true
        lastRequestTime = frame.timestamp
        let captured = frame.capturedImage
        let stamp = frame.timestamp
        workQueue.async { [weak self] in
            guard let self else { return }
            var observations: [Pinch] = []
            do {
                let handler = VNImageRequestHandler(cvPixelBuffer:captured,
                                                     orientation:.right,
                                                     options:[:])
                try handler.perform([self.request])
                for hand in self.request.results ?? [] {
                    guard let thumb = try? hand.recognizedPoint(.thumbTip),
                          let index = try? hand.recognizedPoint(.indexTip),
                          let wrist = try? hand.recognizedPoint(.wrist),
                          let mcp = try? hand.recognizedPoint(.indexMCP),
                          [thumb,index,wrist,mcp].allSatisfy({ $0.confidence >= 0.52 }) else {
                        continue
                    }
                    let gap = hypot(thumb.location.x-index.location.x,
                                    thumb.location.y-index.location.y)
                    let handSize = max(0.06,
                        hypot(mcp.location.x-wrist.location.x,
                              mcp.location.y-wrist.location.y))
                    let closed = gap < min(0.11,max(0.030,handSize*0.43))
                    observations.append(Pinch(center: CGPoint(
                        x:(thumb.location.x+index.location.x)*0.5,
                        y:(thumb.location.y+index.location.y)*0.5),
                        closed:closed))
                }
            } catch {
                // Temporary poor lighting/occlusion must not cause drift.
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                let (action,label) = self.update(
                    observations: observations, timestamp: stamp)
                deliver(action,label)
            }
        }
    }

    private func update(observations:[Pinch], timestamp:TimeInterval) -> (Change,String) {
        let pinches = observations.filter(\.closed).sorted { $0.center.x < $1.center.x }
        let count = min(pinches.count,2)
        guard count > 0 else {
            reset()
            return (.none,"Hand tracking: no confident pinch. Touch controls remain available.")
        }
        lastVisibleAt = timestamp
        if count != lastMode {
            reset()
            lastMode = count
        }
        stableCount += 1
        let alpha: CGFloat = 0.43
        let points = (0..<count).map { index -> CGPoint in
            let raw = pinches[index].center
            guard index < previousSmoothed.count else { return raw }
            let before = previousSmoothed[index]
            return CGPoint(x:before.x+(raw.x-before.x)*alpha,
                           y:before.y+(raw.y-before.y)*alpha)
        }
        previousSmoothed = points
        // Two detections required to avoid transient/false gestures.
        guard stableCount >= 2 else {
            if count == 1 { previousOne = points[0] }
            return (.none,"Pinch acquired. Hold the gesture steady to manipulate.")
        }
        if count == 1 {
            previousTwo = nil
            let point = points[0]
            defer { previousOne = point }
            guard let before = previousOne else {
                return (.none,"One pinch: move the volume.")
            }
            let x = point.x - before.x
            let y = point.y - before.y
            if hypot(x,y) < 0.0025 { return (.none,"One pinch: moving volume.") }
            return (.translate(max(-0.035,min(0.035,x)),
                               max(-0.035,min(0.035,y))),
                    "One pinch: translating volume relative to its anchor.")
        }
        previousOne = nil
        let a = points[0], b = points[1]
        let dist = hypot(b.x-a.x,b.y-a.y)
        guard dist >= 0.10 else {
            previousTwo = nil
            return (.none,"Spread both hands further apart for reliable control.")
        }
        let mid = CGPoint(x:(a.x+b.x)*0.5,y:(a.y+b.y)*0.5)
        let angle = atan2(b.y-a.y,b.x-a.x)
        defer { previousTwo = (mid,dist,angle) }
        guard let old = previousTwo else {
            return (.none,"Two pinches: scale and rotate.")
        }
        let factor = max(0.90,min(1.10,dist/max(0.01,old.distance)))
        var deltaAngle = angle-old.angle
        while deltaAngle > .pi { deltaAngle -= 2 * .pi }
        while deltaAngle < -.pi { deltaAngle += 2 * .pi }
        let turn = max(-0.08,min(0.08,(mid.x-old.center.x)*1.2))
        return (.transform(scale:factor,twist:max(-0.12,min(0.12,deltaAngle)),
                           turn:turn),
                "Two pinches: scaling and rotating volume.")
    }
}
