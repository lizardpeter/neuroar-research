import SwiftUI
import ARKit
import SceneKit
import MetalKit
import QuartzCore
import GeometryCore
import simd

/// Deliberately separate from patient-facing Live AR.
/// A real ARAnchor is created only after an explicit surface raycast.
/// Nothing follows the camera and no anatomical registration is claimed.
struct AnchoredVolumeARCanvas: UIViewRepresentable {
    @ObservedObject var imaging: MRIPlanningModel
    @Binding var trackingStatus: String
    @Binding var gestureStatus: String
    @Binding var handTelemetry: HandTelemetry
    @Binding var lidarStatus: String
    @Binding var isPlaced: Bool
    let active: Bool
    let handEnabled: Bool
    let handMode: OneHandMode
    let placementRequest: Int
    let resetRequest: Int
    let resetTransformRequest: Int
    let depthOcclusion: Bool
    let renderSamples: UInt32
    let displayMode: VolumeDisplayMode
    let threshold: Double
    let opacity: Double

    func makeCoordinator() -> Coordinator { Coordinator(parent:self) }

    func makeUIView(context: Context) -> ARSCNView {
        let ar = ARSCNView(frame:.zero)
        ar.scene = SCNScene()
        ar.autoenablesDefaultLighting = false
        ar.automaticallyUpdatesLighting = false
        ar.session.delegate = context.coordinator
        ar.session.delegateQueue = .main
        ar.allowsCameraControl = false
        context.coordinator.arView = ar
        if let renderer = context.coordinator.renderer {
            let overlay = MTKView(frame:.zero,device:renderer.device)
            renderer.source = .tabletop
            renderer.arView = ar
            renderer.configure(view:overlay,transparent:true)
            overlay.isUserInteractionEnabled = false
            overlay.translatesAutoresizingMaskIntoConstraints = false
            ar.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo:ar.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo:ar.trailingAnchor),
                overlay.topAnchor.constraint(equalTo:ar.topAnchor),
                overlay.bottomAnchor.constraint(equalTo:ar.bottomAnchor)
            ])
            context.coordinator.metalOverlay = overlay
        }
        context.coordinator.installTouch(on:ar)
        context.coordinator.updateView()
        return ar
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateView()
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
        uiView.session.delegate = nil
        coordinator.renderer?.isActive = false
        coordinator.renderer?.arView = nil
        coordinator.metalOverlay?.delegate = nil
        coordinator.arView = nil
        coordinator.handInput.reset()
    }

    final class Coordinator: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
        var parent: AnchoredVolumeARCanvas
        weak var arView: ARSCNView?
        weak var metalOverlay: MTKView?
        let renderer = MedicalVolumeRenderer()
        let handInput = VisionHandInput()
        private var running = false
        private var activeAnchor: ARAnchor?
        private var lidarAvailable = false
        private var lastPlaceRequest = 0
        private var lastResetRequest = 0
        private var lastResetTransformRequest = 0
        private var lastTrackingStatus = ""
        private var lastHandStatus = ""
        private var lastTelemetryUI = 0.0
        private var lastLidarStatus = ""
        private var wasTrackingNormal = false

        init(parent:AnchoredVolumeARCanvas) {
            self.parent = parent
            super.init()
        }

        func updateView() {
            guard let arView else { return }
            renderer?.load(parent.imaging.volume,revision:parent.imaging.volumeRevision)
            renderer?.window = parent.imaging.window
            renderer?.displayMode = parent.displayMode
            renderer?.threshold = Float(parent.threshold)
            renderer?.opacity = Float(parent.opacity)
            renderer?.useSceneDepth = lidarAvailable && parent.depthOcclusion
            renderer?.quality = parent.handEnabled
                ? min(parent.renderSamples, 96) : parent.renderSamples
            renderer?.isActive = parent.active
            metalOverlay?.isPaused = !parent.active
            if parent.active && !running { startSession() }
            else if !parent.active && running {
                arView.session.pause()
                running = false
                handInput.reset()
                renderer?.isActive = false
                clearAnchor()
            }
            if parent.resetRequest != lastResetRequest {
                lastResetRequest = parent.resetRequest
                clearAnchor()
                renderer?.resetInteraction()
                report("Reposition: scan a horizontal surface, then tap to place.")
            }
            if parent.placementRequest != lastPlaceRequest {
                lastPlaceRequest = parent.placementRequest
                place(at:CGPoint(x:arView.bounds.midX,y:arView.bounds.midY))
            }
            if parent.resetTransformRequest != lastResetTransformRequest {
                lastResetTransformRequest = parent.resetTransformRequest
                renderer?.resetInteraction()
                report("Transform reset. The world anchor remains in place.")
            }
            if !parent.handEnabled { handInput.reset() }
        }

        private func startSession() {
            guard let arView, ARWorldTrackingConfiguration.isSupported else {
                report("World tracking is unavailable on this device.")
                return
            }
            clearAnchor()
            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = .gravity
            config.planeDetection = [.horizontal]
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                config.sceneReconstruction = .meshWithClassification
                lidarAvailable = true
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
                lidarAvailable = true
            } else {
                lidarAvailable = false
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                config.frameSemantics.insert(.smoothedSceneDepth)
            }
            renderer?.useSceneDepth = lidarAvailable && parent.depthOcclusion
            let message = lidarAvailable
                ? "LiDAR mesh raycasts + smoothed depth enabled"
                : "Visual-inertial AR (no LiDAR scene mesh available)"
            if message != lastLidarStatus {
                lastLidarStatus = message
                parent.lidarStatus = message
            }
            arView.session.run(config,options:[.resetTracking,.removeExistingAnchors])
            running = true
            wasTrackingNormal = false
            report("Scan a table or floor, then tap the surface to place the volume.")
        }

        private func report(_ text:String) {
            guard text != lastTrackingStatus else { return }
            lastTrackingStatus = text
            parent.trackingStatus = text
        }

        private func reportHand(_ text:String) {
            guard text != lastHandStatus else { return }
            lastHandStatus = text
            parent.gestureStatus = text
        }

        /// No arbitrary camera-relative fallback: never fabricate a placement
        /// at 65 cm when LiDAR/ARKit has not actually found a surface.
        private func place(at screenPoint: CGPoint) {
            guard let arView, running,
                  let frame=arView.session.currentFrame,
                  case .normal = frame.camera.trackingState else {
                report("Tracking is not stable. Slowly scan the table and retry.")
                return
            }
            // ARSCNView exposes raycastQuery; ARView's direct raycast method
            // is not available on SceneKit. Let the ARSession execute queries.
            let planeQuery = arView.raycastQuery(from:screenPoint,
                                                 allowing:.existingPlaneGeometry,
                                                 alignment:.horizontal)
            let planes = planeQuery.map { arView.session.raycast($0) } ?? []
            let candidates: [ARRaycastResult]
            if planes.isEmpty {
                let estimated = arView.raycastQuery(from:screenPoint,
                                                    allowing:.estimatedPlane,
                                                    alignment:.horizontal)
                candidates = estimated.map { arView.session.raycast($0) } ?? []
            } else {
                candidates = planes
            }
            guard let hit = candidates.first else {
                report("No horizontal surface at reticle. Move your phone to scan a table or floor.")
                return
            }
            clearAnchor()
            let anchor = ARAnchor(name:"NeuroAR-VirtualVolume",transform:hit.worldTransform)
            activeAnchor = anchor
            renderer?.anchorTransform = hit.worldTransform
            renderer?.resetInteraction()
            arView.session.add(anchor:anchor)
            parent.isPlaced = true
            report("AR-anchored scan placed. Move around it; camera motion must not translate the model.")
        }

        private func clearAnchor() {
            if let activeAnchor,let arView {
                arView.session.remove(anchor:activeAnchor)
            }
            activeAnchor = nil
            renderer?.anchorTransform = nil
            parent.isPlaced = false
            handInput.reset()
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            updateAnchors(anchors)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            updateAnchors(anchors)
        }

        private func updateAnchors(_ anchors: [ARAnchor]) {
            guard let id=activeAnchor?.identifier else { return }
            for anchor in anchors where anchor.identifier == id {
                activeAnchor = anchor
                // Only ARKit-originated anchor localization updates this pose.
                renderer?.anchorTransform = anchor.transform
            }
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            guard let id=activeAnchor?.identifier,
                  anchors.contains(where:{ $0.identifier == id }) else { return }
            activeAnchor = nil
            renderer?.anchorTransform = nil
            parent.isPlaced = false
            report("AR anchor was lost; scan and place again.")
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Detection and live confidence diagnostics work BEFORE
            // placement, and even when ARKit is still relocalizing.
            // Run detection whenever Demo AR is visible, including BEFORE
            // placement. The HUD can therefore diagnose camera/lighting
            // problems independently of AR anchors and volume rendering.
            guard parent.active else { return }
            if parent.handEnabled {
            handInput.process(frame:frame,isEnabled:true,mode:parent.handMode) {
                [weak self] change,telemetry in
                guard let self,self.parent.active,self.parent.handEnabled else { return }
                let now=CACurrentMediaTime()
                if now-self.lastTelemetryUI >= 0.18 ||
                    self.parent.handTelemetry.visible != telemetry.visible {
                    self.lastTelemetryUI = now
                    self.parent.handTelemetry = telemetry
                    self.reportHand(telemetry.status)
                }
                // We still detect the hand when unplaced / tracking limited,
                // but never apply a gesture unless a stable world anchor exists.
                guard self.activeAnchor != nil,
                      let frame=self.arView?.session.currentFrame,
                      case .normal = frame.camera.trackingState else { return }
                switch change {
                case .none: break
                case let .move(x,y):
                    self.renderer?.moveInView(dx:Float(x*0.55),
                                              dy:Float(y*0.55))
                case let .rotate(x,y,roll):
                    self.renderer?.rotate(dx:Float(x),dy:Float(y),
                                          roll:Float(roll))
                case let .scale(factor):
                    self.renderer?.scale(by:Float(factor))
                case let .smartMove(x,y,factor,roll):
                    self.renderer?.moveInView(dx:Float(x*0.40),dy:Float(y*0.40))
                    self.renderer?.scale(by:Float(factor))
                    self.renderer?.rotate(dx:0,dy:0,roll:Float(roll))
                }
            }
            }
            if lidarAvailable {
                let meshCount = frame.anchors.reduce(into:0) { count, anchor in
                    if anchor is ARMeshAnchor { count += 1 }
                }
                let depthLive = frame.smoothedSceneDepth != nil
                let state = "LiDAR mesh: \(meshCount) chunks · depth " +
                    (depthLive ? "live" : "acquiring")
                if state != lastLidarStatus {
                    lastLidarStatus = state
                    parent.lidarStatus = state
                }
            }
            guard case .normal = frame.camera.trackingState else {
                if wasTrackingNormal {
                    wasTrackingNormal = false
                    handInput.reset()
                    report("World tracking limited: volume hidden to prevent apparent drift.")
                }
                return
            }
            if !wasTrackingNormal {
                wasTrackingNormal = true
                if activeAnchor == nil {
                    report("Tracking ready. Tap the detected horizontal surface to place.")
                } else {
                    report("AR anchor tracked. Volume stays fixed in room coordinates.")
                }
            }

        }

        func installTouch(on view:ARSCNView) {
            let placeTap = UITapGestureRecognizer(target:self,action:#selector(onPlaceTap(_:)))
            let orbit = UIPanGestureRecognizer(target:self,action:#selector(onRotate(_:)))
            orbit.maximumNumberOfTouches = 1
            let move = UIPanGestureRecognizer(target:self,action:#selector(onTranslate(_:)))
            move.minimumNumberOfTouches = 2
            move.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target:self,action:#selector(onScale(_:)))
            let twist = UIRotationGestureRecognizer(target:self,action:#selector(onTwist(_:)))
            for gesture in [placeTap,orbit,move,pinch,twist] {
                gesture.delegate = self
                view.addGestureRecognizer(gesture)
            }
            placeTap.require(toFail:orbit)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer) -> Bool {
            !(recognizer is UITapGestureRecognizer) &&
                !(other is UITapGestureRecognizer)
        }

        @objc private func onPlaceTap(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended,activeAnchor == nil,let arView else { return }
            place(at:tap.location(in:arView))
        }

        @objc private func onRotate(_ pan:UIPanGestureRecognizer) {
            guard let arView,activeAnchor != nil else { return }
            let p=pan.translation(in:arView)
            if pan.state == .changed {
                renderer?.rotate(dx:Float(p.x)*0.005,dy:Float(p.y)*0.005)
            }
            pan.setTranslation(.zero,in:arView)
        }

        @objc private func onTranslate(_ pan:UIPanGestureRecognizer) {
            guard let arView,activeAnchor != nil else { return }
            let p=pan.translation(in:arView)
            if pan.state == .changed {
                renderer?.moveInView(dx:Float(p.x)*0.0005,dy:-Float(p.y)*0.0005)
            }
            pan.setTranslation(.zero,in:arView)
        }

        @objc private func onScale(_ pinch:UIPinchGestureRecognizer) {
            if pinch.state == .changed,activeAnchor != nil {
                renderer?.scale(by:Float(pinch.scale))
            }
            pinch.scale = 1
        }

        @objc private func onTwist(_ twist:UIRotationGestureRecognizer) {
            if twist.state == .changed,activeAnchor != nil {
                renderer?.rotate(dx:0,dy:0,roll:-Float(twist.rotation))
            }
            twist.rotation = 0
        }
    }
}

/// Compact controls; the camera stays visible so placement and LiDAR scan are
/// not obscured by a full-screen "glass" control panel.
struct DemoARWorkspace: View {
    @ObservedObject var imaging: MRIPlanningModel
    let active: Bool
    @State private var handEnabled = true
    @State private var handMode: OneHandMode = .smart
    @State private var handTelemetry = HandTelemetry()
    @State private var placed = false
    @State private var placeRequest = 0
    @State private var resetRequest = 0
    @State private var resetTransformRequest = 0
    @State private var depthOcclusion = true
    @State private var renderSamples: UInt32 = 128
    @State private var tracking = "Scan a horizontal surface to start."
    @State private var handStatus = "Show one free hand to the rear camera."
    @State private var lidar = "Checking ARKit capabilities…"
    @State private var controls = false
    @State private var displayMode: VolumeDisplayMode = .composite
    @State private var threshold = 0.28
    @State private var opacity = 1.0

    var body: some View {
        ZStack {
            AnchoredVolumeARCanvas(
                imaging:imaging,trackingStatus:$tracking,gestureStatus:$handStatus,
                handTelemetry:$handTelemetry,
                lidarStatus:$lidar,isPlaced:$placed,
                active:active,handEnabled:handEnabled,handMode:handMode,
                placementRequest:placeRequest,resetRequest:resetRequest,
                resetTransformRequest:resetTransformRequest,
                depthOcclusion:depthOcclusion,renderSamples:renderSamples,
                displayMode:displayMode,threshold:threshold,opacity:opacity)
                .ignoresSafeArea(edges:.horizontal)
            if !placed {
                Image(systemName:"plus.viewfinder")
                    .font(.system(size:46,weight:.ultraLight))
                    .foregroundStyle(.cyan.opacity(0.8))
                    .allowsHitTesting(false)
            }
            VStack(spacing:10) {
                VStack(alignment:.leading,spacing:7) {
                    HStack {
                        Label("ANCHORED VOLUMETRIC AR",systemImage:"cube.transparent")
                            .font(.caption.bold())
                        Spacer()
                        Button { controls = true } label: {
                            Image(systemName:"slider.horizontal.3")
                        }.accessibilityLabel("Volume and gesture controls")
                    }
                    Text(tracking).font(.footnote)
                    HStack(spacing:7) {
                        Circle()
                            .fill(handEnabled && handTelemetry.visible
                                  ? Color.green : Color.gray)
                            .frame(width:9,height:9)
                        Text(handEnabled ? handTelemetry.status : "Hand tracking paused")
                            .font(.caption2).lineLimit(2)
                        Spacer(minLength:2)
                        if handEnabled {
                            Text(String(format:"%.0f ms",handTelemetry.processingMs))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    Text(lidar).font(.caption2).foregroundStyle(.cyan)
                    Text("Virtual research model · NOT registered to a person")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
                .padding(12)
                .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16))
                Spacer()
                VStack(spacing:8) {
                    HStack(spacing:10) {
                        Button(placed ? "Reposition" : "Place at reticle") {
                            if placed { resetRequest += 1 }
                            else { placeRequest += 1 }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        Button("Reset view") {
                            resetTransformRequest += 1
                        }.buttonStyle(.bordered)
                    }
                    Toggle(isOn:$handEnabled) {
                        Label("One-hand tracking",systemImage:"hand.raised")
                            .font(.caption)
                    }.tint(.teal)
                    Picker("Hand gesture action",selection:$handMode) {
                        ForEach(OneHandMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }.pickerStyle(.segmented).disabled(!handEnabled)
                    Text(handMode.instruction)
                        .font(.caption2).foregroundStyle(.secondary)
                    Picker("Rendering",selection:$displayMode) {
                        ForEach(VolumeDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.segmented)
                    Text(placed
                         ? "Touch: one-finger rotate • two-finger move • pinch zoom • twist roll"
                         : "Aim at a table, move the phone to map it, then tap to place.")
                        .font(.caption2)
                }
                .padding(12)
                .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16))
            }
            .padding(12)
        }
        .environment(\.colorScheme,.dark)
        .sheet(isPresented:$controls) {
            NavigationStack {
                Form {
                    Section("Volume visualization") {
                        Picker("Technique",selection:$displayMode) {
                            ForEach(VolumeDisplayMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        HStack {
                            Text("Threshold")
                            Slider(value:$threshold,in:0.01...0.95)
                        }
                        HStack {
                            Text("Density")
                            Slider(value:$opacity,in:0.20...3.0)
                        }
                        Picker("Render quality",selection:$renderSamples) {
                            Text("Smooth").tag(UInt32(80))
                            Text("Balanced").tag(UInt32(128))
                            Text("Detailed").tag(UInt32(192))
                        }.pickerStyle(.segmented)
                        Text("Hand tracking automatically reduces ray samples to reserve GPU time.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Direct volume compositing samples the actual image intensities. MIP projects maximum intensity. Surface mode displays an intensity threshold, not segmented anatomy.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("One-hand gestures") {
                        Toggle("Enable one-hand tracking",isOn:$handEnabled)
                        Picker("Action",selection:$handMode) {
                            ForEach(OneHandMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }.pickerStyle(.segmented)
                        Text(handMode.instruction).font(.caption)
                        Text(handTelemetry.status).font(.caption)
                        HStack {
                            Text("Vision detection")
                            Spacer()
                            Text(handTelemetry.visible ? "HAND FOUND" : "NO HAND")
                                .foregroundStyle(handTelemetry.visible ? .green : .secondary)
                        }
                        LabeledContent("Joint confidence",
                                       value:String(format:"%.0f%%",handTelemetry.confidence*100))
                        LabeledContent("Thumb / index gap",
                                       value:String(format:"%.2f × palm",handTelemetry.pinchRatio))
                        LabeledContent("Detection rate",
                                       value:String(format:"%.1f fps",handTelemetry.fps))
                        LabeledContent("Vision processing",
                                       value:String(format:"%.0f ms",handTelemetry.processingMs))
                        Text("If it says NO HAND, the camera cannot see sufficient finger landmarks. With a free hand in the rear-camera view, use a bright textured background, keep the entire hand in frame, and avoid motion blur. Detection works before placing the volume.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Smart: one-hand pinch moves the model; approach/retreat changes apparent palm size; wrist twist rolls; open palm rotates. The Move, Rotate and Scale modes offer more predictable pinch-based control.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Tracking and placement") {
                        Text(lidar)
                        Toggle("Real-world depth occlusion",isOn:$depthOcclusion)
                        Text("LiDAR scene reconstruction and smoothed depth are enabled only on supported devices. The volume is placed using an explicit ARKit horizontal-surface raycast and ARAnchor; no camera-relative placement fallback exists.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Reposition on another surface") { resetRequest += 1; controls=false }
                    }
                    Section {
                        Text("Research visualization only: no clinical registration, verified skull segmentation, surgical trajectories or positioning accuracy.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .navigationTitle("Volume AR Controls")
                .toolbar {
                    ToolbarItem(placement:.confirmationAction) {
                        Button("Done") { controls = false }
                    }
                }
            }
        }
    }
}

struct VirtualStudioWorkspace: View {
    @ObservedObject var imaging:MRIPlanningModel
    let active: Bool
    @State private var mode:VolumeDisplayMode = .composite
    @State private var threshold = 0.28
    @State private var opacity = 1.0

    var body:some View {
        VStack(spacing:0) {
            ZStack(alignment:.topLeading) {
                VolumeStudioCanvas(imaging:imaging,displayMode:$mode,
                                   threshold:$threshold,opacity:$opacity,
                                   active:active)
                VStack(alignment:.leading,spacing:4) {
                    Text("3D VOXEL VOLUME").font(.caption.bold()).tracking(1)
                    Text(imaging.volume.description).font(.caption2)
                        .lineLimit(2).foregroundStyle(.secondary)
                }
                .padding(11)
                .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12))
                .padding(12)
            }
            .frame(maxWidth:.infinity,maxHeight:.infinity)
            VStack(spacing:9) {
                Picker("Volume renderer",selection:$mode) {
                    ForEach(VolumeDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented)
                HStack {
                    Text("Threshold").font(.caption).frame(width:70,alignment:.leading)
                    Slider(value:$threshold,in:0.01...0.95)
                    Text(String(format:"%.2f",threshold))
                        .font(.caption.monospacedDigit()).frame(width:35)
                }
                if mode == .composite {
                    HStack {
                        Text("Opacity").font(.caption).frame(width:70,alignment:.leading)
                        Slider(value:$opacity,in:0.20...3.0)
                    }
                }
                Text("Drag to orbit · pinch to zoom · twist to roll. Direct GPU sampling of the imported voxels, not a fake skull mesh.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Research-only imaging preview. No anatomical segmentation or patient registration.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            .padding(12)
            .background(NeuroStyle.card)
        }
        .background(NeuroStyle.canvas)
    }
}
