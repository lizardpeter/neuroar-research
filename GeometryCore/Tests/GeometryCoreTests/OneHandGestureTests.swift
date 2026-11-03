import XCTest
import Foundation
@testable import GeometryCore

final class OneHandGestureTests: XCTestCase {
    private func sample(_ x:CGFloat=0.40,_ y:CGFloat=0.50,
                        palm:CGFloat=0.14,gap:CGFloat=0.32,
                        fingers:Int=0,roll:CGFloat=0)->HandLandmarks {
        HandLandmarks(center:CGPoint(x:x,y:y),palmSize:palm,
                      wristAngle:roll,pinchRatio:gap,
                      fingersExtended:fingers,confidence:0.9)
    }

    func testOnePinchMovesWithoutSecondHand() {
        var core=OneHandGestureInterpreter()
        _=core.process(sample(),mode:.move)
        _=core.process(sample(),mode:.move)
        let (change,_)=core.process(sample(0.49,0.50),mode:.move)
        guard case let .move(dx,dy)=change else { XCTFail("One pinch should move");return }
        XCTAssertGreaterThan(dx,0)
        XCTAssertEqual(dy,0)
    }

    func testOnePinchRotateAndRoll() {
        var core=OneHandGestureInterpreter()
        _=core.process(sample(),mode:.rotate)
        _=core.process(sample(),mode:.rotate)
        let (change,_)=core.process(sample(0.49,0.55,roll:0.22),mode:.rotate)
        guard case let .rotate(yaw,pitch,roll)=change else {
            XCTFail("One pinch should rotate");return
        }
        XCTAssertGreaterThan(yaw,0)
        XCTAssertGreaterThan(pitch,0)
        XCTAssertGreaterThan(roll,0)
    }

    func testOneHandScaleInBothDirections() {
        var core=OneHandGestureInterpreter()
        _=core.process(sample(),mode:.scale)
        _=core.process(sample(),mode:.scale)
        let (increase,_)=core.process(sample(0.40,0.58),mode:.scale)
        guard case let .scale(up)=increase else { XCTFail("Missing scale");return }
        XCTAssertGreaterThan(up,1)
        let (decrease,_)=core.process(sample(0.40,0.36),mode:.scale)
        guard case let .scale(down)=decrease else { XCTFail("Missing reverse scale");return }
        XCTAssertLessThan(down,1)
    }

    func testOpenPalmOrbitsInSmartMode() {
        var core=OneHandGestureInterpreter()
        let open=sample(palm:0.14,gap:1.10,fingers:4)
        _=core.process(open,mode:.smart)
        _=core.process(open,mode:.smart)
        let (change,_)=core.process(sample(0.51,0.50,palm:0.14,
                                            gap:1.10,fingers:4),mode:.smart)
        guard case let .rotate(yaw,_,_)=change else {
            XCTFail("Open palm should orbit");return
        }
        XCTAssertGreaterThan(yaw,0)
    }

    func testDisappearanceAndReclutchDoNotJump() {
        var core=OneHandGestureInterpreter()
        _=core.process(sample(),mode:.move)
        _=core.process(sample(),mode:.move)
        _=core.process(sample(0.45),mode:.move)
        let (lost,_)=core.process(nil,mode:.move)
        guard case .none=lost else { XCTFail("Lost hand cannot move");return }
        let (recovered,_)=core.process(sample(0.95),mode:.move)
        guard case .none=recovered else { XCTFail("Reclutch jump");return }
    }

    func testNoAccidentalOpenPalmRotationInMoveMode() {
        var core=OneHandGestureInterpreter()
        let open=sample(gap:1.15,fingers:4)
        _=core.process(open,mode:.move)
        _=core.process(open,mode:.move)
        let (change,_)=core.process(sample(0.60,gap:1.15,fingers:4),mode:.move)
        guard case .none=change else { XCTFail("Move requires pinch");return }
    }
}
