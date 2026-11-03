import Foundation

// Pure, platform-independent one-hand clutch state machine.
// Kept in GeometryCore so gesture regressions run in ordinary Swift CI.

public enum OneHandMode: String, CaseIterable, Identifiable {
    case smart = "Smart"
    case move = "Move"
    case rotate = "Rotate"
    case scale = "Scale"
    public var id: String { rawValue }
    public var instruction: String {
        switch self {
        case .smart: return "Pinch and move to grab; approach/retreat to resize; wrist twist to roll. Open palm and move to rotate."
        case .move: return "Pinch thumb and index; move the pinched hand to reposition."
        case .rotate: return "Pinch and move left/right/up/down to orbit; twist wrist to roll."
        case .scale: return "Pinch and move UP to enlarge or DOWN to shrink."
        }
    }
}

public struct HandLandmarks {
    public var center: CGPoint
    public var palmSize: CGFloat
    public var wristAngle: CGFloat
    public var pinchRatio: CGFloat
    public var fingersExtended: Int
    public var confidence: Float

    public init(center:CGPoint,palmSize:CGFloat,wristAngle:CGFloat,
                pinchRatio:CGFloat,fingersExtended:Int,confidence:Float) {
        self.center=center;self.palmSize=palmSize;self.wristAngle=wristAngle
        self.pinchRatio=pinchRatio;self.fingersExtended=fingersExtended
        self.confidence=confidence
    }
    enum Pose: Equatable { case pinch, open, neutral }
    func pose(wasPinching: Bool) -> Pose {
        if pinchRatio < (wasPinching ? 0.82 : 0.60) { return .pinch }
        if fingersExtended >= 3 && pinchRatio > 0.85 { return .open }
        return .neutral
    }
}

public struct OneHandGestureInterpreter {
    public init() {}
    public enum Change {
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

    public mutating func reset() {
        pose = .neutral
        proposed = .neutral
        consecutive = 0
        previous = nil
        missing = 0
    }

    public mutating func process(_ sample: HandLandmarks?, mode: OneHandMode) -> (Change,String) {
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
