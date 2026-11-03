import Foundation
import ARKit
import Vision
import CoreGraphics
import QuartzCore

import GeometryCore

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
        let interval:Double = (thermal == .serious || thermal == .critical) ? 0.12 : 0.050
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
