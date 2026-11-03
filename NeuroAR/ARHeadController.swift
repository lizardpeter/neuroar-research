import Foundation
import UIKit
import Combine
import ARKit
import RealityKit
import simd
import GeometryCore

final class ARHeadController: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var study: Study = .synthetic
    @Published private(set) var selectedIndex = 0
    @Published private(set) var capturedPoints: [Point3] = []
    @Published private(set) var registration: RegistrationResult?
    @Published private(set) var heldOutSurfaceResidualMeters: Double?
    @Published private(set) var status = "Point the rear camera toward a stationary head."
    @Published private(set) var lidarSupported = false
    @Published private(set) var trackingIsNormal = false
    @Published private(set) var depthMm = 30.0
    @Published private(set) var meshImported = false
    @Published private(set) var plannerLinked = false
    @Published private(set) var faceVisible = false
    @Published private(set) var naturalHeadBound = false
    @Published private(set) var surfaceTrackingActive = false
    @Published private(set) var surfaceMotionRMSEmeters: Double?
    @Published private(set) var naturalFeatureCount = 0
    @Published private(set) var naturalFitRMSEmeters: Double?
    @Published private(set) var surfaceFitRMSEmeters: Double?
    @Published private(set) var lastPhantomDiagnostic: PhantomDepthStatistics?
    @Published var phantomOnlyAcknowledged = false
    private var scalpSamplePointsMeters: [Point3] = []
    private let naturalTracker = NaturalHeadTracker()
    private var naturalReference: NaturalHeadObservation?
    private var latestNaturalObservation: NaturalHeadObservation?
    private var baselineMRIToWorld: simd_float4x4?
    private var currentMRIToWorld: simd_float4x4?
    private var lastNaturalFrameTime: TimeInterval?
    private var lastFacialFrameTime: TimeInterval?
    private var surfaceReferenceCloud: [Point3] = []
    private var surfaceReferenceMRIToWorld: simd_float4x4?
    private var headCloudCenterWorld: Point3?
    private var surfaceReferenceTimestamp: TimeInterval?
    private var surfaceEstimationInFlight = false
    private let surfaceEstimationQueue = DispatchQueue(label: "neuroar.head-surface-icp", qos: .userInitiated)
    private var acquisitionEpoch = UUID()
    var availableMRIFeatures: Int {
        (try? NaturalFaceRegistration.mriFeatures(study.landmarks).count) ?? 0
    }
    var canRefineSurface: Bool {
        registration != nil && scalpSamplePointsMeters.count >= 15 &&
        naturalHeadBound && (latestNaturalObservation?.faceCloudMeters.count ?? 0) >= 25
    }


    weak var arView: ARView?
    private var root: Entity?
    private var anchor: AnchorEntity?
    private var customMesh: Entity?
    private var intensityPreview: Entity?
    private var roiPreview: Entity?
    private var markerAnchors: [AnchorEntity] = []
    private var lastTrackingNormal = false
    private var frameCount = 0

    var nextLandmark: StudyLandmark? {
        capturedPoints.count < study.landmarks.count ? study.landmarks[capturedPoints.count] : nil
    }
    var activeTrajectory: StudyTrajectory? {
        study.trajectories.indices.contains(selectedIndex) ? study.trajectories[selectedIndex] : nil
    }

    func connect(to view: ARView) {
        clearRegistration(reason:"New AR session. Look toward the rear camera for marker-free tracking.")
        self.arView = view
        view.automaticallyConfigureSession = false
        view.session.delegate = self
        view.session.delegateQueue = .main
        lidarSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        guard lidarSupported else {
            status = "Requires a LiDAR-equipped iPhone or iPad for landmark capture."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        config.worldAlignment = .gravity
        // No ARReferenceImage or attached physical marker is required.
        // The rear-camera RGB + LiDAR feed is processed with Apple Vision.
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// TabView can retain offscreen tabs, so disappearing from the tab does
    /// not necessarily dismantle the camera view. Stop capture explicitly.
    func suspendCamera(reason: String = "AR view inactive; registration cleared.") {
        arView?.session.pause()
        clearRegistration(reason: reason)
        trackingIsNormal = false
    }

    func resumeCameraIfMounted() {
        guard let view = arView else { return } // makeUIView starts new tabs
        connect(to: view) // always starts a fresh, unregistered session
    }

    func disconnect(from view: ARView) {
        view.session.pause()
        if arView === view {
            clearRegistration(reason:"AR camera closed; all world-space landmarks invalidated.")
            arView=nil
            trackingIsNormal=false
        }
    }

    /// A valid natural face establishes the MRI-to-world pose. On short losses
    /// of facial features, a LiDAR surface estimate can maintain that pose for
    /// a strictly bounded interval. This is research-only, not navigation.
    private func handleNaturalHead(_ observation: NaturalHeadObservation?) {
        guard arView != nil, trackingIsNormal else { return }
        guard let observation else {
            faceVisible = false
            surfaceTrackingActive = false
            updateHeadFollower()
            return
        }
        faceVisible = observation.features.count >= 3
        naturalFeatureCount = observation.features.count
        latestNaturalObservation = observation
        guard faceVisible else {
            updateHeadFollower() // Hide stale pose until a new surface fit succeeds.
            continueFromHeadSurface(observation)
            return
        }
        do {
            if !naturalHeadBound {
                let base: simd_float4x4
                if let registration {
                    // The manually annotated pose may seed a *demo*, but does
                    // not identify the real-world subject automatically.
                    base = worldFromMRI(registration)
                } else {
                    let annotated = try NaturalFaceRegistration.mriFeatures(study.landmarks)
                    let fit = try NaturalFaceRegistration.fit(mri: annotated,
                                                               camera: observation.features)
                    registration = fit.transform
                    naturalFitRMSEmeters = fit.rmsMeters
                    base = worldFromMRI(fit.transform)
                }
                baselineMRIToWorld = base
                currentMRIToWorld = base
                naturalReference = observation
                naturalHeadBound = true
                render()
            } else {
                guard let reference = naturalReference, let base = baselineMRIToWorld else {
                    clearRegistration(reason: "Natural face baseline unavailable. Reacquire.")
                    return
                }
                let delta = try NaturalFaceRegistration.motion(reference: reference.features,
                                                                observed: observation.features)
                let next = worldFromMRI(delta.transform) * base
                if let previous = currentMRIToWorld {
                    let difference = next.columns.3 - previous.columns.3
                    let jump = simd_length(SIMD3<Float>(difference.x,difference.y,difference.z))
                    guard jump < 0.06 else { throw NaturalFaceError.excessiveMotion }
                }
                currentMRIToWorld = next
                naturalFitRMSEmeters = delta.rmsMeters
            }
            lastFacialFrameTime = observation.timestamp
            lastNaturalFrameTime = observation.timestamp
            surfaceTrackingActive = false
            surfaceMotionRMSEmeters = nil
            updateSurfaceReference(observation.faceCloudMeters, timestamp: observation.timestamp)
            updateHeadFollower()
            status = String(format: "Natural face tracking: %d features. Fit %.1f mm (NOT target accuracy).",
                            observation.features.count, (naturalFitRMSEmeters ?? 0) * 1000)
        } catch {
            // Never silently switch the physical subject or keep a stale pose.
            clearRegistration(reason: "Natural head correspondence rejected: \(error.localizedDescription). Reacquire.")
        }
    }

    private func updateSurfaceReference(_ cloud: [Point3], timestamp: TimeInterval) {
        guard cloud.count >= 80, let pose = currentMRIToWorld else { return }
        surfaceReferenceCloud = cloud
        surfaceReferenceMRIToWorld = pose
        surfaceReferenceTimestamp = timestamp
        headCloudCenterWorld = cloud.reduce(Point3(0, 0, 0), +) * (1.0 / Double(cloud.count))
    }

    private func continueFromHeadSurface(_ observation: NaturalHeadObservation) {
        // Surface-to-surface ICP is nontrivial mobile computation. Snapshot the
        // geometry on main, run the fit off-thread, then apply the result only
        // if no newer facial or surface observation superseded its baseline.
        guard naturalHeadBound,
              let faceTime = lastFacialFrameTime,
              observation.timestamp - faceTime < 1.8,
              surfaceReferenceMRIToWorld != nil,
              let referenceTime = surfaceReferenceTimestamp,
              surfaceReferenceCloud.count >= 80 else {
            surfaceTrackingActive = false
            updateHeadFollower()
            return
        }
        guard !surfaceEstimationInFlight else { return }
        surfaceEstimationInFlight = true
        let previousCloud = surfaceReferenceCloud
        let epoch = acquisitionEpoch
        let currentCloud = observation.faceCloudMeters
        surfaceEstimationQueue.async { [weak self] in
            let result = Result { try HeadSurfaceMotion.estimate(previousMeters: previousCloud,
                                                                 currentMeters: currentCloud) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.acquisitionEpoch == epoch else { return }
                self.surfaceEstimationInFlight = false
                guard self.trackingIsNormal, self.naturalHeadBound,
                      (self.arView?.session.currentFrame?.timestamp ?? .infinity) - observation.timestamp < 0.4,
                      !self.faceVisible,
                      self.lastFacialFrameTime == faceTime,
                      self.surfaceReferenceTimestamp == referenceTime,
                      observation.timestamp - faceTime < 1.8,
                      let previousPose = self.surfaceReferenceMRIToWorld else { return }
                switch result {
                case .success(let motion):
                    self.currentMRIToWorld = self.worldFromMRI(motion.delta) * previousPose
                    self.lastNaturalFrameTime = observation.timestamp
                    self.surfaceTrackingActive = true
                    self.surfaceMotionRMSEmeters = motion.fittedRMSEMeters
                    self.updateSurfaceReference(currentCloud, timestamp: observation.timestamp)
                    self.updateHeadFollower()
                    self.status = String(format:
                        "Short-term LiDAR surface continuation: %.1f mm fitted error. Not anatomical accuracy.",
                        motion.fittedRMSEMeters * 1000)
                case .failure:
                    self.surfaceTrackingActive = false
                    self.updateHeadFollower()
                    self.status = "Head partially hidden; LiDAR surface match rejected. Overlay hidden."
                }
            }
        }
    }

    private func worldFromMRI(_ result:RegistrationResult)->simd_float4x4 {
        let q=result.quaternionWXYZ
        var matrix=simd_float4x4(simd_quatf(ix:Float(q[1]),iy:Float(q[2]),iz:Float(q[3]),r:Float(q[0])))
        let t=result.translationMeters
        matrix.columns.3=SIMD4<Float>(Float(t.x),Float(t.y),Float(t.z),1)
        return matrix
    }

    private func updateHeadFollower() {
        guard let root else { return }
        let timestamp = arView?.session.currentFrame?.timestamp ?? .infinity
        let source = OverlayTrackingGate.source(
            cameraNormal: trackingIsNormal,
            headBound: naturalHeadBound,
            hasPose: currentMRIToWorld != nil,
            faceVisible: faceVisible,
            surfaceTracking: surfaceTrackingActive,
            secondsSinceFace: lastFacialFrameTime.map { timestamp - $0 },
            secondsSinceMotion: lastNaturalFrameTime.map { timestamp - $0 })
        if source != .hidden, let current = currentMRIToWorld {
            root.transform = Transform(matrix: current)
            root.isEnabled = true
        } else {
            // Stale callbacks must never leave an MRI overlay glued to space.
            root.isEnabled = false
        }
    }

    func recordPhantomDiagnostic() {
        guard phantomOnlyAcknowledged else {
            status="Only run sensor diagnostics against a consenting synthetic mannequin/phantom. Confirm phantom mode first."
            return
        }
        guard lidarSupported,trackingIsNormal,faceVisible,
              let observed=latestNaturalObservation else {
            status="LiDAR tracking and a naturally detected phantom face are required."
            return
        }
        guard let metrics = PhantomDepthStatistics.analyze(observed.faceCloudMeters) else {
            status="Not enough high-confidence depth samples; no result recorded."
            return
        }
        lastPhantomDiagnostic=metrics
        status=String(format:"Phantom sensor capture: %d samples; spatial spread %.1f mm (NOT depth accuracy).",metrics.sampleCount,metrics.spatialSpreadMm)
    }

    /// An OPTIONAL externally segmented scalp-to-LiDAR refinement, seeded by
    /// the natural face fit. Fitted ICP residual is not anatomical TRE.
    func refineScalpSurface() {
        guard canRefineSurface, trackingIsNormal, let fit = registration,
              let observed = latestNaturalObservation else {
            status = "Refinement needs a labelled scalp mask, a naturally acquired head, and enough LiDAR face samples."
            return
        }
        do {
            let cloud = observed.faceCloudMeters
            let report = try TrimmedSurfaceICP.refine(sourceMeters: scalpSamplePointsMeters,
                                                      observedMeters: cloud, initial: fit)
            guard report.matchedPointCount >= 25,
                  report.fittedRMSEMeters < 0.012 else {
                throw SurfaceRegistrationError.unstableFit
            }
            registration = report.transform
            naturalReference = observed
            baselineMRIToWorld = worldFromMRI(report.transform)
            currentMRIToWorld = baselineMRIToWorld
            updateSurfaceReference(observed.faceCloudMeters, timestamp: observed.timestamp)
            surfaceFitRMSEmeters = report.fittedRMSEMeters
            status = String(format:"Experimental natural-face ICP: %.1f mm over %d correspondences. NOT target registration accuracy.",
                            report.fittedRMSEMeters * 1000, report.matchedPointCount)
            render()
        } catch {
            status = "Natural scalp refinement rejected: \(error.localizedDescription). Original pose retained."
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARSession.delegateQueue defaults to main. Keep it explicitly main
        // so state/epoch reads below cannot race with published UI updates.
        frameCount += 1
        let normal: Bool
        switch frame.camera.trackingState { case .normal: normal = true; default: normal = false }
        trackingIsNormal = normal
        if lastTrackingNormal && !normal && naturalHeadBound {
            clearRegistration(reason: "ARKit tracking interrupted; MRI overlay disabled.")
        }
        lastTrackingNormal = normal
        if let lastTime = lastNaturalFrameTime, frame.timestamp - lastTime > 0.75 {
            // A missed callback must not let the overlay float over a moving head.
            surfaceTrackingActive = false
            faceVisible = false
        }
        if let lastFace = lastFacialFrameTime,
           frame.timestamp - lastFace > 1.8 && naturalHeadBound {
            clearRegistration(reason: "Head surface continuation expired. Show the face to register again.")
        }
        updateHeadFollower()
        guard normal, frameCount % 2 == 0 else { return }
        naturalTracker.submit(frame: frame, expectedHeadCenterWorld: headCloudCenterWorld) {
            [weak self, epoch = acquisitionEpoch] observation in
            guard let self, self.acquisitionEpoch == epoch else { return }
            self.handleNaturalHead(observation)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.clearRegistration(reason:"Session interrupted. Registration cleared.")
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.clearRegistration(reason:"AR session failed: \(error.localizedDescription)")
        }
    }

    func captureLandmark(at location: CGPoint, viewportSize: CGSize) {
        guard lidarSupported, trackingIsNormal else {
            status = "LiDAR and normal camera tracking are required."
            return
        }
        guard nextLandmark != nil, let arView, let frame = arView.session.currentFrame else { return }
        let orientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        do {
            let point = try DepthUnprojector.worldPoint(at:location,
                    viewportSize:viewportSize,orientation:orientation,frame:frame)
            capturedPoints.append(point)
            let marker=AnchorEntity(world:SIMD3<Float>(Float(point.x),Float(point.y),Float(point.z)))
            marker.addChild(ModelEntity(mesh:.generateSphere(radius:0.004),
                                        materials:[SimpleMaterial(color:.systemYellow,isMetallic:false)]))
            arView.scene.addAnchor(marker)
            markerAnchors.append(marker)
            status = "Landmark \(capturedPoints.count) of \(study.landmarks.count) captured."
            if capturedPoints.count == study.landmarks.count { fitLandmarks() }
        } catch {
            status = error.localizedDescription
        }
    }

    private func fitLandmarks() {
        do {
            let sources = study.landmarks.map {
                Point3($0.pointMm.x/1000,$0.pointMm.y/1000,$0.pointMm.z/1000)
            }
            let report = try LandmarkRegistrationEvaluator.evaluate(sourceMeters:sources,targetMeters:capturedPoints)
            let result = report.fit
            // A low landmark-fit error does NOT establish clinical target registration accuracy.
            // Thresholds here are demonstration guards, not surgical acceptance criteria.
            guard result.landmarkRMSEmeters <= 0.015 else {
                clearRegistration(reason:"Landmark fit exceeds the 15 mm demonstration guard. Retake points.")
                return
            }
            if let residual=report.heldOutSurfaceResidualMeters, residual > 0.03 {
                clearRegistration(reason:"Independent surface landmark mismatch >30 mm (demo guard). Retake the entire correspondence set. Not clinical accuracy.")
                return
            }
            registration=result
            heldOutSurfaceResidualMeters=report.heldOutSurfaceResidualMeters
            status=String(format:"Demo fit residual %.1f mm; \(report.hasHeldOutPoint ? "last external landmark held out" : "NO independent landmark check"). NOT intracranial accuracy.",result.landmarkRMSEmeters*1000)
            render()
        } catch {
            clearRegistration(reason:"Could not fit landmarks: \(error.localizedDescription)")
        }
    }

    func clearRegistration(reason: String = "Registration reset. Retake landmarks.") {
        registration=nil; heldOutSurfaceResidualMeters=nil;capturedPoints=[]
        surfaceFitRMSEmeters=nil
        naturalHeadBound=false; faceVisible=false; naturalFeatureCount=0
        surfaceTrackingActive=false; surfaceMotionRMSEmeters=nil
        surfaceReferenceCloud=[]; surfaceReferenceMRIToWorld=nil; headCloudCenterWorld=nil
        surfaceReferenceTimestamp=nil; surfaceEstimationInFlight=false
        naturalReference=nil; latestNaturalObservation=nil
        baselineMRIToWorld=nil; currentMRIToWorld=nil; lastNaturalFrameTime=nil
        lastFacialFrameTime=nil
        naturalFitRMSEmeters=nil;acquisitionEpoch=UUID()
        markerAnchors.forEach { $0.removeFromParent() }
        markerAnchors=[]
        anchor?.removeFromParent(); anchor=nil; root=nil
        status=reason
    }

    func importStudy(url: URL) {
        let opened=url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        do {
            let data=try Data(contentsOf:url)
            let loaded=try JSONDecoder().decode(Study.self,from:data)
            guard loaded.landmarks.count >= 3, !loaded.trajectories.isEmpty,
                loaded.landmarks.allSatisfy({ $0.pointMm.allFinite }),
                loaded.trajectories.allSatisfy({ $0.entryMm.allFinite && $0.targetMm.allFinite }) else {
                status="Invalid study: needs three landmarks and finite trajectories."
                return
            }
            study=loaded; selectedIndex=0; depthMm=min(30,loaded.trajectories[0].lengthMm)
            customMesh=nil; intensityPreview=nil; roiPreview=nil
            scalpSamplePointsMeters=[]
            plannerLinked=false; meshImported=false
            clearRegistration(reason:"Loaded \(loaded.title). Capture corresponding facial landmarks.")
        } catch { status="Study import error: \(error.localizedDescription)" }
    }

    /// Explicit bridge from the *same image* used in the MRI planner.
    /// A fresh landmark registration is mandatory and any prior world-space
    /// anchor is invalidated. This is visualization, NOT instrument guidance.
    func importPlanningStudy(study planned:Study, intensitySurface:PreviewSurface?,
                             roiSurface:PreviewSurface?, scalpMaskDesignated:Bool, displayedDepthMm:Double) {
        clearRegistration(reason:"MRI linked. Point at the face to acquire natural features using RGB and LiDAR. MRI feature annotations are required; no physical markers.")
        study=planned
        selectedIndex=0
        depthMm=min(max(0,displayedDepthMm),planned.trajectories.first?.lengthMm ?? 0)
        customMesh=nil;meshImported=false
        plannerLinked=true
        // Bound geometry for phone memory. Coarse previews never establish anatomy.
        intensityPreview=makePreviewEntity(intensitySurface,color:UIColor.systemGray.withAlphaComponent(0.35))
        roiPreview=makePreviewEntity(roiSurface,color:UIColor.systemCyan.withAlphaComponent(0.45))
        scalpSamplePointsMeters = scalpMaskDesignated ?
            (roiSurface?.verticesMm ?? []).prefix(12000).map { Point3($0.x/1000,$0.y/1000,$0.z/1000) } : []
        if intensityPreview == nil && roiPreview == nil {
            status += " No segmented 3D surface available; trajectories and landmarks only."
        }
    }

    func invalidatePlanningLink() {
        guard plannerLinked else { return }
        clearRegistration(reason:"MRI image changed. AR study and registration invalidated; relink the new MRI explicitly.")
        study = .synthetic
        selectedIndex = 0
        depthMm = 30
        intensityPreview=nil;roiPreview=nil;scalpSamplePointsMeters=[]
        plannerLinked=false
    }

    private func makePreviewEntity(_ preview:PreviewSurface?,color:UIColor)->Entity? {
        guard let preview, !preview.verticesMm.isEmpty else { return nil }
        let limit = min(preview.verticesMm.count/3, 12_000)
        guard limit > 0 else { return nil }
        let positions:[SIMD3<Float>] = preview.verticesMm.prefix(limit*3).map { p in
            SIMD3<Float>(Float(p.x/1000),Float(p.y/1000),Float(p.z/1000))
        }
        var meshDescriptor = MeshDescriptor(name:"Unvalidated coarse MRI preview")
        meshDescriptor.positions = MeshBuffers.Positions(positions)
        meshDescriptor.primitives = .triangles((0..<positions.count).map { UInt32($0) })
        do {
            let mesh = try MeshResource.generate(from:[meshDescriptor])
            return ModelEntity(mesh:mesh,materials:[SimpleMaterial(color:color,isMetallic:false)])
        } catch {
            status="3D AR preview unavailable: \(error.localizedDescription). Landmarks and paths remain available."
            return nil
        }
    }

    func importMesh(url: URL) {
        Task { @MainActor in
            let access=url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let entity=try await Entity(contentsOf:url)
                // Imported USDZ geometry MUST already use MRI coordinates in METERS.
                // 1 mm in study JSON corresponds to 0.001 unit in the mesh.
                customMesh=entity
                meshImported=true
                status="Anatomy mesh loaded. Registration required for overlay."
                render()
            } catch { status="USDZ import error: \(error.localizedDescription)" }
        }
    }

    func selectTrajectory(_ idx: Int) {
        guard study.trajectories.indices.contains(idx) else { return }
        selectedIndex=idx
        depthMm=min(30,study.trajectories[idx].lengthMm)
        render()
    }
    func setDepth(_ value: Double) {
        depthMm=max(0,min(value,activeTrajectory?.lengthMm ?? 0))
        render()
    }
    func coordinate(entry: Bool, axis: Int) -> Double {
        guard let tr=activeTrajectory else { return 0 }
        return entry ? tr.entryMm[axis] : tr.targetMm[axis]
    }
    func setCoordinate(entry: Bool, axis: Int, value: Double) {
        guard study.trajectories.indices.contains(selectedIndex), axis >= 0, axis < 3 else { return }
        if entry { study.trajectories[selectedIndex].entryMm[axis]=value }
        else { study.trajectories[selectedIndex].targetMm[axis]=value }
        depthMm=min(depthMm,activeTrajectory?.lengthMm ?? 0)
        render()
    }

    private func render() {
        anchor?.removeFromParent(); anchor=nil; root=nil
        guard let registration,let arView else { return }
        let sceneAnchor=AnchorEntity(world:.zero)
        let sceneRoot=Entity()
        let q=registration.quaternionWXYZ
        sceneRoot.orientation=simd_quatf(ix:Float(q[1]),iy:Float(q[2]),iz:Float(q[3]),r:Float(q[0]))
        let t=registration.translationMeters
        sceneRoot.position=SIMD3<Float>(Float(t.x),Float(t.y),Float(t.z))
        sceneAnchor.addChild(sceneRoot)
        arView.scene.addAnchor(sceneAnchor)
        anchor=sceneAnchor; root=sceneRoot
        updateHeadFollower()

        if plannerLinked {
            if let intensityPreview {
                intensityPreview.removeFromParent()
                sceneRoot.addChild(intensityPreview)
            }
            if let roiPreview {
                roiPreview.removeFromParent()
                sceneRoot.addChild(roiPreview)
            }
        } else if let customMesh {
            customMesh.removeFromParent()
            sceneRoot.addChild(customMesh)
        } else if study.isSynthetic {
            // Synthetic model, NOT reconstructed patient anatomy.
            let brain=ModelEntity(mesh:.generateSphere(radius:1),
                materials:[SimpleMaterial(color:UIColor.systemTeal.withAlphaComponent(0.42),isMetallic:false)])
            brain.scale=SIMD3<Float>(0.072,0.088,0.076)
            sceneRoot.addChild(brain)
        }
        guard let plan=activeTrajectory else { return }
        let entry=meters(plan.entryMm), target=meters(plan.targetMm)
        let tip=meters(plan.atDepth(depthMm))
        sceneRoot.addChild(ball(at:entry,radius:0.005,color:.systemOrange))
        sceneRoot.addChild(ball(at:target,radius:0.004,color:.systemPurple))
        sceneRoot.addChild(ball(at:tip,radius:0.005,color:.systemYellow))
        if simd_distance(entry,tip) > 0.001 {
            sceneRoot.addChild(segment(from:entry,to:tip,radius:0.0015,color:.systemYellow))
        }
        if simd_distance(tip,target) > 0.001 {
            sceneRoot.addChild(segment(from:tip,to:target,radius:0.00065,color:.systemGray))
        }
    }
    private func meters(_ p: Point3) -> SIMD3<Float> {
        SIMD3<Float>(Float(p.x/1000),Float(p.y/1000),Float(p.z/1000))
    }
    private func ball(at p: SIMD3<Float>,radius:Float,color:UIColor) -> Entity {
        let entity=ModelEntity(mesh:.generateSphere(radius:radius),materials:[SimpleMaterial(color:color,isMetallic:false)])
        entity.position=p
        return entity
    }
    private func segment(from a:SIMD3<Float>,to b:SIMD3<Float>,radius:Float,color:UIColor) -> Entity {
        let delta=b-a
        let length=simd_length(delta)
        let entity=ModelEntity(mesh:.generateCylinder(height:length,radius:radius),
                               materials:[SimpleMaterial(color:color,isMetallic:false)])
        entity.position=(a+b)/2
        entity.orientation=simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(delta))
        return entity
    }
}
