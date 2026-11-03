import Foundation
import ARKit
import Vision
import CoreGraphics
import QuartzCore

enum OneHandMode: String, CaseIterable, Identifiable {
    case smart = "Smart"
    case move = "Move"
    case rotate = "Rotate"
    case scale = "Scale"
    var id: String { rawValue }
    var instruction: String {
        switch self {
        case .smart: return "Pinch and move to grab; approach/retreat to resize; wrist twist to roll. Open palm and move to rotate."
        case .move: return "Pinch thumb and index; move the pinched hand to reposition."
        case .rotate: return "Pinch and move left/right/up/down to orbit; twist wrist to roll."
        case .scale: return "Pinch and move UP to enlarge or DOWN to shrink."
        }
    }
}

struct HandTelemetry: Equatable {
    var status = "Show your free hand to the rear camera."
    var center: CGPoint? = nil
    var confidence: Float = 0
    var pinchRatio: Double = 0
    var fps: Double = 0
    var processingMs: Double = 0
    var visible: Bool { center != nil }
}

/// All coordinates are normalized Vision portrait image coordinates.
/// This interpreter does not require ARKit, hardware, or multiple hands.
struct HandLandmarks {
    var center: CGPoint
    var palmSize: CGFloat
    var wristAngle: CGFloat
    var pinchRatio: CGFloat
    var fingersExtended: Int
    var confidence: Float

    enum Pose: Equatable { case pinch, open, neutral }
    func pose(wasPinching: Bool) -> Pose {
        if pinchRatio < (wasPinching ? 0.82 : 0.60) { return .pinch }
        if fingersExtended >= 3 && pinchRatio > 0.85 { return .open }
        return .neutral
    }
}

struct OneHandGestureInterpreter {
    enum Change {
        case none
        case move(CGFloat,CGFloat)
        case rotate(CGFloat,CGFloat,CGFloat)
        case scale(CGFloat)
        case smartMove(CGFloat,CGFloat,CGFloat,CGFloat)
    }
    private var pose: HandLandmarks.Pose = .neutral
    private var proposed: HandLandmarks.Pose = .neutral
    private var consecutive = 0
    private var previous: HandLandmarks?
    private var missing = 0

    mutating func reset() {
        pose = .neutral
        proposed = .neutral
        consecutive = 0
        previous = nil
        missing = 0
    }

    mutating func process(_ sample: HandLandmarks?, mode: OneHandMode) -> (Change,String) {
        guard let current = sample else {
            missing += 1
            previous = nil // never bridge a gap with a huge jump
            if missing >= 2 { reset() }
            return (.none,"No hand detected — open your hand in view of the rear camera.")
        }
        missing = 0
        let kind = current.pose(wasPinching: pose == .pinch)
        if kind != proposed { proposed = kind; consecutive = 1 }
        else { consecutive += 1 }
        if kind != pose {
            guard consecutive >= 2 else {
                previous = nil
                return (.none,"Recognizing hand gesture…")
            }
            pose = kind
            previous = nil
        }
        guard pose != .neutral else {
            previous = nil
            return (.none,"Hand detected. Make a pinch or show an open palm.")
        }
        guard let old = previous else {
            previous = current
            return (.none,pose == .pinch ? "PINCH ENGAGED" : "OPEN PALM ENGAGED")
        }
        // A responsive one-pole filter reduces jitter without buffering
        // frames. The newest observation moves over halfway to the target.
        let smoothing: CGFloat = 0.56
        var smooth = current
        smooth.center = CGPoint(
            x: old.center.x + smoothing*(current.center.x-old.center.x),
            y: old.center.y + smoothing*(current.center.y-old.center.y))
        smooth.palmSize = old.palmSize + smoothing*(current.palmSize-old.palmSize)
        smooth.wristAngle = old.wristAngle +
            smoothing*Self.angle(current.wristAngle-old.wristAngle)
        previous = smooth
        func dead(_ x:CGFloat,_ threshold:CGFloat) -> CGFloat {
            abs(x) < threshold ? 0 : x
        }
        let x = Self.clamp(dead(smooth.center.x-old.center.x,0.0017),-0.06,0.06)
        let y = Self.clamp(dead(smooth.center.y-old.center.y,0.0017),-0.06,0.06)
        let roll = Self.clamp(dead(Self.angle(smooth.wristAngle-old.wristAngle),0.012),-0.13,0.13)
        if mode == .smart && pose == .open {
            return (.rotate(x*3.2,y*3.2,0),"OPEN PALM · orbit")
        }
        guard pose == .pinch else {
            return (.none,"Pinch thumb and index to control \(mode.rawValue).")
        }
        switch mode {
        case .move: return (.move(x,y),"PINCH · move")
        case .rotate: return (.rotate(x*3.5,y*3.5,roll),"PINCH · rotate")
        case .scale:
            let factor = Self.clamp(CGFloat(exp(Double(y)*4.5)),0.85,1.17)
            return (.scale(factor),"PINCH · resize")
        case .smart:
            let factor = Self.clamp(smooth.palmSize/max(CGFloat(0.025),old.palmSize),0.90,1.10)
            return (.smartMove(x,y,factor,roll),"PINCH · move/resize/wrist roll")
        }
    }

    private static func angle(_ raw:CGFloat) -> CGFloat {
        var a = raw
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
    private static func clamp(_ x:CGFloat,_ a:CGFloat,_ b:CGFloat)->CGFloat {
        min(b,max(a,x))
    }
}

/// One background Vision request at a time. No 2-hand requirement, no timer
/// backlog and no image readback from the Metal renderer.
final class VisionHandInput {
    typealias Change = OneHandGestureInterpreter.Change
    private let queue=DispatchQueue(label:"neuroar.hand-vision",qos:.userInitiated)
    private let request=VNDetectHumanHandPoseRequest()
    private var pending=false
    private var generation:UInt64=0
    private var previousStart:TimeInterval = -.infinity
    private var previousComplete:TimeInterval = -.infinity
    private var currentMode:OneHandMode = .smart
    private var interpreter=OneHandGestureInterpreter()

    init() { request.maximumHandCount=1 }

    func reset() {
        generation &+= 1
        interpreter.reset()
        previousComplete = -.infinity
    }

    func process(frame:ARFrame,isEnabled:Bool,mode:OneHandMode,
                 deliver:@escaping (Change,HandTelemetry)->Void) {
        guard isEnabled else { return }
        if mode != currentMode { currentMode=mode; reset() }
        let thermal=ProcessInfo.processInfo.thermalState
        let interval:Double = (thermal == .serious || thermal == .critical) ? 0.15 : 0.075
        guard !pending, frame.timestamp-previousStart >= interval else { return }
        pending=true
        previousStart=frame.timestamp
        let pixelBuffer=frame.capturedImage
        let stamp=frame.timestamp
        let token=generation
        let start=CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self else { return }
            var observation:HandLandmarks?
            do {
                let handler=VNImageRequestHandler(cvPixelBuffer:pixelBuffer,
                                                   orientation:.right,options:[:])
                try handler.perform([self.request])
                observation=self.request.results?.compactMap(Self.extract).first
            } catch { observation=nil }
            let elapsed=(CACurrentMediaTime()-start)*1000
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending=false
                guard self.generation == token,self.currentMode == mode else { return }
                let fps=self.previousComplete.isFinite && stamp>self.previousComplete
                    ? 1/(stamp-self.previousComplete) : 0
                self.previousComplete=stamp
                let (change,label)=self.interpreter.process(observation,mode:mode)
                var info=HandTelemetry()
                info.status=label
                info.center=observation?.center
                info.confidence=observation?.confidence ?? 0
                info.pinchRatio=Double(observation?.pinchRatio ?? 0)
                info.fps=min(60,fps)
                info.processingMs=elapsed
                deliver(change,info)
            }
        }
    }

    private static func extract(_ hand:VNHumanHandPoseObservation)->HandLandmarks? {
        func joint(_ name:VNHumanHandPoseObservation.JointName,
                   minConfidence:Float=0.34)->VNRecognizedPoint? {
            guard let p=try? hand.recognizedPoint(name),
                  p.confidence >= minConfidence else { return nil }
            return p
        }
        guard let thumb=joint(.thumbTip,minConfidence:0.24) ?? joint(.thumbIP,minConfidence:0.30),
              let index=joint(.indexTip,minConfidence:0.24) ?? joint(.indexDIP,minConfidence:0.30),
              let wrist=joint(.wrist),let indexBase=joint(.indexMCP),
              let pinkyBase=joint(.littleMCP) else { return nil }
        let middleBase=joint(.middleMCP)
        let width=hypot(indexBase.location.x-pinkyBase.location.x,
                        indexBase.location.y-pinkyBase.location.y)
        let end=middleBase?.location ?? indexBase.location
        let length=hypot(end.x-wrist.location.x,end.y-wrist.location.y)
        let palm=max(0.025,max(width,length))
        let gap=hypot(thumb.location.x-index.location.x,
                      thumb.location.y-index.location.y)
        let pinchCenter=CGPoint(x:(index.location.x+thumb.location.x)*0.5,
                                y:(index.location.y+thumb.location.y)*0.5)
        let openCenter=CGPoint(x:(indexBase.location.x+pinkyBase.location.x+wrist.location.x)/3,
                               y:(indexBase.location.y+pinkyBase.location.y+wrist.location.y)/3)
        let pairs:[(VNHumanHandPoseObservation.JointName,
                    VNHumanHandPoseObservation.JointName)] = [
            (.indexTip,.indexMCP),(.middleTip,.middleMCP),
            (.ringTip,.ringMCP),(.littleTip,.littleMCP)]
        var extended=0
        for (tipName,baseName) in pairs {
            guard let tip=joint(tipName,minConfidence:0.26),
                  let base=joint(baseName,minConfidence:0.26) else { continue }
            let tipD=hypot(tip.location.x-wrist.location.x,
                           tip.location.y-wrist.location.y)
            let baseD=hypot(base.location.x-wrist.location.x,
                            base.location.y-wrist.location.y)
            if tipD > baseD + palm*0.21 { extended += 1 }
        }
        let center=extended >= 3 && gap/palm > 0.85 ? openCenter : pinchCenter
        return HandLandmarks(center:center,palmSize:palm,
                             wristAngle:atan2(end.y-wrist.location.y,
                                              end.x-wrist.location.x),
                             pinchRatio:gap/palm,fingersExtended:extended,
                             confidence:min(thumb.confidence,index.confidence,
                                            wrist.confidence,indexBase.confidence,
                                            pinkyBase.confidence))
    }
}
