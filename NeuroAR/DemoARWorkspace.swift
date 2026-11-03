import SwiftUI
import SceneKit
import ARKit
import Vision
import CoreGraphics
import GeometryCore
import simd

/// Tabletop-only AR. The virtual model has no physical-head registration.
/// Uses rear-camera AR world tracking, not ARFaceTrackingConfiguration.
struct DemoARCanvas: UIViewRepresentable {
    @ObservedObject var imaging: MRIPlanningModel
    @Binding var handControlEnabled: Bool
    @Binding var gestureStatus: String
    var active: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.autoenablesDefaultLighting = true
        view.automaticallyUpdatesLighting = true
        view.antialiasingMode = .multisampling4X
        view.session.delegate = context.coordinator
        view.session.delegateQueue = .main
        context.coordinator.view = view
        view.scene.rootNode.addChildNode(context.coordinator.model)
        context.coordinator.installTouchGestures(on: view)
        context.coordinator.refreshScene()
        context.coordinator.updateSessionIfNeeded()
        return view
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
        uiView.session.delegate = nil
        coordinator.view = nil
        coordinator.resetHandBaseline()
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refreshSceneIfNeeded()
        context.coordinator.updateSessionIfNeeded()
    }

    final class Coordinator: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
        var parent: DemoARCanvas
        weak var view: ARSCNView?
        let model = SCNNode()
        private let visionQueue = DispatchQueue(label: "neuroar.tabletop-vision-hand", qos: .userInitiated)
        private var processingHand = false
        private var lastVisionFrame: TimeInterval = -.infinity
        private var lastRevision = -1
        private var lastSliceKey = ""
        private var placed = false
        private var sessionActive = false
        private var oneHand: CGPoint?
        private var twoHands: (center: CGPoint, length: CGFloat, angle: CGFloat)?
        private var statusText = ""

        init(_ parent: DemoARCanvas) {
            self.parent = parent
            model.name = "Unregistered tabletop research display"
            super.init()
        }

        func report(_ message: String) {
            guard statusText != message else { return }
            statusText = message
            parent.gestureStatus = message
        }

        func updateSessionIfNeeded() {
            guard let view else { return }
            if parent.active && !sessionActive {
                guard ARWorldTrackingConfiguration.isSupported else {
                    report("AR world tracking is unavailable on this device.")
                    return
                }
                let config = ARWorldTrackingConfiguration()
                config.worldAlignment = .gravity
                view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                sessionActive = true
                placed = false
            } else if !parent.active && sessionActive {
                view.session.pause()
                sessionActive = false
                resetHandBaseline()
                placed = false
            }
        }

        func resetHandBaseline() {
            oneHand = nil
            twoHands = nil
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            if !placed {
                let camera = frame.camera.transform
                let forward = SIMD3<Float>(-camera.columns.2.x, -camera.columns.2.y, -camera.columns.2.z)
                let eye = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
                model.simdPosition = eye + forward * 0.65
                placed = true
            }
            guard parent.active, parent.handControlEnabled else {
                resetHandBaseline()
                return
            }
            guard case .normal = frame.camera.trackingState else {
                resetHandBaseline()
                report("AR tracking limited. Hold the phone steady; hand controls paused.")
                return
            }
            guard !processingHand, frame.timestamp - lastVisionFrame > 0.16 else { return }
            lastVisionFrame = frame.timestamp
            processingHand = true
            let pixels = frame.capturedImage
            visionQueue.async { [weak self] in
                let request = VNDetectHumanHandPoseRequest()
                request.maximumHandCount = 2
                var found: [PinchedHand] = []
                do {
                    // Portrait rear-camera sensor orientation. 2D observations
                    // control display transforms, not measured 3D hand positions.
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixels,
                                                        orientation: .right, options: [:])
                    try handler.perform([request])
                    for hand in request.results ?? [] {
                        guard let thumb = try? hand.recognizedPoint(.thumbTip),
                              let index = try? hand.recognizedPoint(.indexTip),
                              thumb.confidence >= 0.4, index.confidence >= 0.4 else { continue }
                        let a = thumb.location
                        let b = index.location
                        let distance = hypot(a.x-b.x, a.y-b.y)
                        guard distance < 0.08 else { continue }
                        found.append(PinchedHand(point: CGPoint(x: (a.x+b.x)*0.5,
                                                                y: (a.y+b.y)*0.5)))
                    }
                } catch {
                    // Unavailable frames and confidence failures are ordinary,
                    // never evidence of a stable gesture.
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.processingHand = false
                    guard self.parent.active, self.parent.handControlEnabled, self.view != nil else { return }
                    self.interpretHands(found)
                }
            }
        }

        private struct PinchedHand {
            let point: CGPoint
        }

        private func interpretHands(_ detected: [PinchedHand]) {
            let hands = detected.sorted { $0.point.x < $1.point.x }
            guard !hands.isEmpty else {
                resetHandBaseline()
                report("Show a pinched hand to move; pinch with both hands to resize/rotate.")
                return
            }
            if hands.count >= 2 {
                oneHand = nil
                let a = hands[0].point, b = hands[1].point
                let center = CGPoint(x: (a.x+b.x)*0.5, y: (a.y+b.y)*0.5)
                let length = hypot(b.x-a.x, b.y-a.y)
                guard length > 0.12 else { resetHandBaseline(); return }
                let angle = atan2(b.y-a.y, b.x-a.x)
                if let last = twoHands {
                    let ratio = min(1.12, max(0.89, length / max(0.01, last.length)))
                    scale(by: Float(ratio))
                    var angleChange = angle - last.angle
                    while angleChange > .pi { angleChange -= 2 * .pi }
                    while angleChange < -.pi { angleChange += 2 * .pi }
                    model.eulerAngles.z += Float(max(-0.14, min(0.14, angleChange)))
                    model.eulerAngles.y += Float(max(-0.08, min(0.08,
                        (center.x-last.center.x) * 1.8)))
                }
                twoHands = (center, length, angle)
                report("Two hands: spread to scale, twist to rotate. Experimental 2D gestures.")
            } else {
                twoHands = nil
                let p = hands[0].point
                if let old = oneHand {
                    let deltaX = max(-0.04, min(0.04, p.x-old.x))
                    let deltaY = max(-0.04, min(0.04, p.y-old.y))
                    model.position.x += Float(deltaX * 0.48)
                    model.position.y += Float(deltaY * 0.48)
                }
                oneHand = p
                report("One pinched hand: move the virtual model. No physical head registration.")
            }
        }

        private func scale(by ratio: Float) {
            let clamped = max(0.45, min(2.8, model.simdScale.x * ratio))
            model.simdScale = SIMD3<Float>(repeating: clamped)
        }

        func installTouchGestures(on view: ARSCNView) {
            let rotate = UIPanGestureRecognizer(target: self, action: #selector(onRotate(_:)))
            rotate.maximumNumberOfTouches = 1
            let move = UIPanGestureRecognizer(target: self, action: #selector(onMove(_:)))
            move.minimumNumberOfTouches = 2
            move.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onScale(_:)))
            let twist = UIRotationGestureRecognizer(target: self, action: #selector(onTwist(_:)))
            for recognizer in [rotate, move, pinch, twist] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func onRotate(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let delta = gesture.translation(in: view)
            if gesture.state == .changed {
                model.eulerAngles.y += Float(delta.x) * 0.007
                model.eulerAngles.x += Float(delta.y) * 0.007
            }
            gesture.setTranslation(.zero, in: view)
        }

        @objc private func onMove(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let delta = gesture.translation(in: view)
            if gesture.state == .changed {
                model.position.x += Float(delta.x) * 0.00055
                model.position.y -= Float(delta.y) * 0.00055
            }
            gesture.setTranslation(.zero, in: view)
        }

        @objc private func onScale(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .changed { scale(by: Float(gesture.scale)) }
            gesture.scale = 1
        }

        @objc private func onTwist(_ gesture: UIRotationGestureRecognizer) {
            if gesture.state == .changed { model.eulerAngles.z -= Float(gesture.rotation) }
            gesture.rotation = 0
        }

        func resetPose() {
            model.eulerAngles = SCNVector3Zero
            model.simdScale = SIMD3<Float>(repeating: 1)
            placed = false
            resetHandBaseline()
            report("Recentered virtual demo. No MRI-to-patient registration.")
        }

        func refreshSceneIfNeeded() {
            let imaging = parent.imaging
            let key = "\(imaging.volumeRevision)/\(imaging.maskRevision)/" +
                "\(imaging.cursorMm.x)/\(imaging.cursorMm.y)/\(imaging.cursorMm.z)/" +
                "\(imaging.window.lowerBound)/\(imaging.window.upperBound)/" +
                "\(imaging.showSlices3D)/\(imaging.showIntensity3D)/\(imaging.showROI3D)/" +
                "\(imaging.tissueSurface?.triangleCount ?? 0)/\(imaging.maskSurface?.triangleCount ?? 0)"
            guard lastSliceKey != key || lastRevision != imaging.volumeRevision else { return }
            lastSliceKey = key
            lastRevision = imaging.volumeRevision
            refreshScene()
        }

        func refreshScene() {
            model.childNodes.forEach { $0.removeFromParentNode() }
            let image = parent.imaging
            let center = image.volume.bounds.center
            // Schematic shells provide spatial context, NOT scan-derived scalp
            // or skull segmentation. Never use them for correspondence.
            let scalp = SCNSphere(radius: 0.105)
            scalp.segmentCount = 48
            scalp.firstMaterial = material(.systemTeal, opacity: 0.12)
            let scalpNode = SCNNode(geometry: scalp)
            scalpNode.scale = SCNVector3(0.83,1.22,1.0)
            scalpNode.name = "Schematic scalp, not reconstructed anatomy"
            model.addChildNode(scalpNode)
            let skull = SCNSphere(radius: 0.092)
            skull.segmentCount = 40
            skull.firstMaterial = material(.white, opacity: 0.10)
            let skullNode = SCNNode(geometry: skull)
            skullNode.scale = SCNVector3(0.83,1.20,0.97)
            skullNode.name = "Schematic skull, not a CT segmentation"
            model.addChildNode(skullNode)

            if image.showSlices3D {
                for plane in ImagingPlane.allCases {
                    if let node = makeSlice(plane, center: center) { model.addChildNode(node) }
                }
            }
            // Threshold surfaces are intentionally labelled as intensity
            // previews, never as anatomically segmented structures.
            if image.showIntensity3D, let mesh = image.tissueSurface {
                model.addChildNode(surfaceNode(mesh, center: center, color: .cyan))
            }
            if image.showROI3D, let roi = image.maskSurface {
                model.addChildNode(surfaceNode(roi, center: center, color: .systemOrange))
            }
        }

        private func material(_ color: UIColor, opacity: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.lightingModel = .physicallyBased
            m.transparency = opacity
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            return m
        }

        private func makeSlice(_ plane: ImagingPlane, center: Point3) -> SCNNode? {
            let imaging = parent.imaging
            let raster = SliceRenderer.render(volume: imaging.volume, mask: imaging.mask,
                                              plane: plane, cursor: imaging.cursorMm,
                                              window: imaging.window, width: 256, height: 256)
            let data = Data(raster.rgba) as CFData
            guard let provider = CGDataProvider(data: data),
                  let image = CGImage(width: raster.width, height: raster.height,
                                      bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: raster.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            let uvPoints = [(0.0,0.0),(1.0,0.0),(0.0,1.0),(1.0,1.0)]
            let vertices = uvPoints.map { u,v -> SCNVector3 in
                let p = raster.frame.world(u: u, v: v)
                return SCNVector3(Float((p.x-center.x)/1000),
                                  Float((p.y-center.y)/1000), Float((p.z-center.z)/1000))
            }
            let texcoords = [CGPoint(x:0,y:1), CGPoint(x:1,y:1),
                             CGPoint(x:0,y:0), CGPoint(x:1,y:0)]
            let geometry = SCNGeometry(sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(textureCoordinates: texcoords)
            ], elements: [SCNGeometryElement(indices: [UInt32(0),1,2,2,1,3],
                                            primitiveType: .triangles)])
            let m = SCNMaterial()
            m.diffuse.contents = UIImage(cgImage: image)
            m.lightingModel = .constant
            m.transparency = 0.84
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            geometry.firstMaterial = m
            let node = SCNNode(geometry: geometry)
            node.name = "Actual research \(plane.rawValue) intensity slice"
            return node
        }

        private func surfaceNode(_ mesh: PreviewSurface, center: Point3,
                                 color: UIColor) -> SCNNode {
            let verts = mesh.verticesMm.map { p in
                SCNVector3(Float((p.x-center.x)/1000), Float((p.y-center.y)/1000),
                           Float((p.z-center.z)/1000))
            }
            let elements = SCNGeometryElement(indices: (0..<verts.count).map(UInt32.init),
                                              primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                                       elements: [elements])
            geometry.firstMaterial = material(color, opacity: 0.26)
            let result = SCNNode(geometry: geometry)
            result.name = "Unvalidated intensity or external ROI preview"
            return result
        }
    }
}

struct DemoARWorkspace: View {
    @ObservedObject var imaging: MRIPlanningModel
    let active: Bool
    @State private var enabled = true
    @State private var gestureStatus = "Move the device to establish tracking."
    @State private var showingInstructions = false

    var body: some View {
        ZStack(alignment: .top) {
            DemoARCanvas(imaging: imaging, handControlEnabled: $enabled,
                         gestureStatus: $gestureStatus, active: active)
                .ignoresSafeArea(edges: .horizontal)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("TABLETOP RESEARCH DEMO", systemImage: "cube.transparent")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Button { showingInstructions = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
                Text(gestureStatus).font(.footnote)
                Toggle("Camera hand gestures", isOn: $enabled)
                    .font(.subheadline)
                Text("Touch: one-finger rotate · two-finger drag · pinch to scale · twist to roll.")
                    .font(.caption2)
                Text("Virtual anatomy and intensity slices are NOT aligned to a patient, physical head, or clinical trajectory.")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(12)
        }
        .sheet(isPresented: $showingInstructions) {
            NavigationStack {
                List {
                    Section("Touch controls") {
                        Text("Drag one finger to rotate in 3D, use two fingers to move, pinch to scale, and twist to roll.")
                    }
                    Section("In-air hand controls") {
                        Text("Point the rear camera at your hands. A thumb-to-index pinch with one hand moves the display in the image plane. Two pinched hands can change scale and rotation.")
                        Text("Vision only observes 2D hand keypoints. It does not measure actual 3D hand depth or surgical-grade pose. Good lighting, unobstructed hands, and a stable AR camera are required.")
                    }
                    Section("Scientific limitations") {
                        Text("Schematic scalp/skull layers are illustrative and not reconstructed from medical images. CT/MRI planes correspond only to the currently selected volume. Registration and anatomical accuracy are unvalidated.")
                    }
                }
                .navigationTitle("Demo Controls")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingInstructions = false }
                    }
                }
            }
        }
    }
}

struct VirtualStudioWorkspace: View {
    @ObservedObject var imaging: MRIPlanningModel

    var body: some View {
        VStack(spacing: 10) {
            TrajectorySceneView(volume: imaging.volume, revision: imaging.volumeRevision,
                                maskRevision: imaging.maskRevision, mask: imaging.mask,
                                cursorMm: imaging.cursorMm, window: imaging.window,
                                tissueSurface: imaging.tissueSurface,
                                maskSurface: imaging.maskSurface, showSlices: imaging.showSlices3D,
                                showTissue: imaging.showIntensity3D, showMask: imaging.showROI3D,
                                entryMm: imaging.entryMm, targetMm: imaging.targetMm,
                                tipMm: imaging.path.atDepth(imaging.depthMm))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Toggle("Slices", isOn: $imaging.showSlices3D)
                Toggle("Intensity surface", isOn: $imaging.showIntensity3D)
            }
            .font(.caption)
            .padding(.horizontal)
            HStack(spacing: 8) {
                Text("Illustrative path depth")
                    .font(.caption)
                Slider(value: Binding(get: { imaging.depthMm },
                                      set: { imaging.setDepth($0) }),
                       in: 0...max(1, imaging.path.lengthMm))
            }.padding(.horizontal)
            Text("Camera-free imaging studio. Surface thresholds are not anatomical segmentations. Not for surgery or navigation.")
                .font(.caption2).foregroundStyle(.orange).padding(.horizontal)
        }
        .padding(.bottom, 10)
        .background(NeuroStyle.canvas)
    }
}
