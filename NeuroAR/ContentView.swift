import SwiftUI
import ARKit
import RealityKit
import UniformTypeIdentifiers
import GeometryCore

struct HeadARView: UIViewRepresentable {
    @ObservedObject var controller: ARHeadController
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    final class Coordinator {
        let controller: ARHeadController
        init(controller: ARHeadController) { self.controller = controller }
    }
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.controller.disconnect(from: view)
    }
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        controller.connect(to: view)
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

enum NeuroStyle {
    static let accent = Color.teal
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

/// Glass is for foreground navigation and interactive controls, not MRI data.
private struct AdaptiveFloatingGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

extension View {
    func neuroFloatingGlass() -> some View { modifier(AdaptiveFloatingGlass()) }
}

private enum Workspace: Hashable { case study, studio, tabletop, camera, validation }

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = ARHeadController()
    @StateObject private var imaging = MRIPlanningModel()
    @State private var workspace: Workspace = .study
    @State private var importingStudy = false
    @State private var importingMesh = false

    var body: some View {
        TabView(selection: $workspace) {
            NavigationStack {
                MRIPlanningView(model: imaging, arController: controller,
                                onOpenAR: { workspace = .camera })
                    .navigationTitle("MRI workspace")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Study", systemImage: "square.stack.3d.up") }
            .tag(Workspace.study)

            NavigationStack {
                VirtualStudioWorkspace(imaging: imaging)
                    .navigationTitle("3D Studio")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Studio", systemImage: "cube.transparent") }
            .tag(Workspace.studio)

            NavigationStack {
                DemoARWorkspace(imaging: imaging,
                                active: workspace == .tabletop && scenePhase == .active)
                    .navigationTitle("Tabletop AR")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Demo AR", systemImage: "hand.draw") }
            .tag(Workspace.tabletop)

            NavigationStack {
                LiveARWorkspace(controller: controller,
                                importStudy: { importingStudy = true },
                                importMesh: { importingMesh = true })
                    .navigationTitle("Live AR")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Live AR", systemImage: "viewfinder") }
            .tag(Workspace.camera)

            NavigationStack {
                ValidationWorkspace(controller: controller, imaging: imaging)
                    .navigationTitle("Validation")
            }
            .tabItem { Label("Validation", systemImage: "checkmark.shield") }
            .tag(Workspace.validation)
        }
        .tint(NeuroStyle.accent)
        .onChange(of: workspace) { oldTab, newTab in
            if oldTab == .camera && newTab != .camera {
                controller.suspendCamera()
            } else if oldTab != .camera && newTab == .camera {
                controller.resumeCameraIfMounted()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                controller.suspendCamera(reason: "Application inactive; head registration cleared.")
            } else if workspace == .camera {
                controller.resumeCameraIfMounted()
            }
        }
        .onChange(of: imaging.volumeRevision) { _, _ in
            controller.invalidatePlanningLink()
        }
        .fileImporter(isPresented: $importingStudy, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { controller.importStudy(url: url) }
        }
        .fileImporter(isPresented: $importingMesh,
                      allowedContentTypes: [UTType(filenameExtension: "usdz") ?? .data]) { result in
            if case let .success(url) = result { controller.importMesh(url: url) }
        }
    }
}

private struct LiveARWorkspace: View {
    @ObservedObject var controller: ARHeadController
    let importStudy: () -> Void
    let importMesh: () -> Void
    @State private var showingControls = false
    @State private var manualLandmarks = false

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                HeadARView(controller: controller)
                    .ignoresSafeArea(edges: .horizontal)
                if manualLandmarks {
                    Color.clear.contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { gesture in
                            controller.captureLandmark(at: gesture.location,
                                                       viewportSize: viewport.size)
                        })
                }
                VStack(spacing: 12) {
                    trackingHUD
                    Spacer(minLength: 8)
                    pathHUD
                }
                .padding(16)
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingControls = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("AR controls and settings")
            }
        }
        .sheet(isPresented: $showingControls) {
            NavigationStack {
                ARControlsSheet(controller: controller,
                                manualLandmarks: $manualLandmarks,
                                importStudy: importStudy, importMesh: importMesh)
                    .navigationTitle("AR controls")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingControls = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var trackingHUD: some View {
        let state = trackingState
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.icon)
                .font(.title3)
                .foregroundStyle(state.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.subheadline.weight(.semibold))
                Text(state.details).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if manualLandmarks, let next = controller.nextLandmark {
                    Text("Manual fallback: tap \(next.name) (\(controller.capturedPoints.count)/\(controller.study.landmarks.count))")
                        .font(.caption2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neuroFloatingGlass()
        .accessibilityElement(children: .combine)
    }

    private var pathHUD: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Research preview", systemImage: "cube.transparent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { showingControls = true } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .frame(minWidth: 34, minHeight: 34)
                }.accessibilityLabel("Open research path controls")
            }
            if let path = controller.activeTrajectory {
                HStack(spacing: 8) {
                    Text(path.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f / %.1f mm", controller.depthMm,
                                RustBridge.pathLengthMm(path)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                Slider(value: Binding(get: { controller.depthMm },
                                      set: { controller.setDepth($0) }),
                       in: 0...max(1, path.lengthMm), step: 0.5)
                    .accessibilityLabel("Illustrative path depth")
            }
            Label("Not for EVD placement or surgical navigation",
                  systemImage: "exclamationmark.shield")
                .font(.caption2.weight(.medium)).foregroundStyle(.orange)
        }
        .padding(15)
        .neuroFloatingGlass()
    }

    private var trackingState: (title: String, details: String, icon: String, color: Color) {
        if !controller.lidarSupported {
            return ("LiDAR unavailable", "This mode requires a compatible LiDAR device.",
                    "sensor.tag.radiowaves.forward", .orange)
        }
        if !controller.trackingIsNormal {
            return ("Camera tracking unavailable", "MRI overlay hidden until tracking recovers.",
                    "camera.metering.unknown", .orange)
        }
        if controller.availableMRIFeatures < 3 {
            return ("MRI correspondence missing", "Annotate matching MRI facial points in Study.",
                    "point.3.connected.trianglepath.dotted", .orange)
        }
        if controller.naturalHeadBound && controller.faceVisible {
            return ("Natural face tracked", "Experimental alignment; not validated anatomical accuracy.",
                    "face.dashed", .green)
        }
        if controller.naturalHeadBound && controller.surfaceTrackingActive {
            return ("LiDAR surface continuation", "Short-term motion estimate; monitor visibility.",
                    "waveform.path", .yellow)
        }
        return (controller.faceVisible ? "Fitting face" : "Searching for a face",
                "The overlay stays hidden until head registration succeeds.", "viewfinder", .orange)
    }
}

private struct ARControlsSheet: View {
    @ObservedObject var controller: ARHeadController
    @Binding var manualLandmarks: Bool
    let importStudy: () -> Void
    let importMesh: () -> Void
    @State private var editingPath = false

    var body: some View {
        Form {
            Section("Study") {
                LabeledContent("Loaded", value: controller.study.title)
                Button { importStudy() } label: {
                    Label("Import study JSON", systemImage: "doc.badge.plus")
                }
                Button { importMesh() } label: {
                    Label("Import anatomy USDZ", systemImage: "cube.transparent")
                }
                Button(role: .destructive) { controller.clearRegistration() } label: {
                    Label("Clear registration", systemImage: "arrow.counterclockwise")
                }
            }
            Section("Natural head tracking") {
                LabeledContent("Camera", value: controller.trackingIsNormal ? "Tracking" : "Unavailable")
                LabeledContent("Facial features", value: "\(controller.naturalFeatureCount)")
                LabeledContent("Head pose", value: controller.naturalHeadBound ? "Experimental fit" : "Not established")
                LabeledContent("LiDAR continuation", value: controller.surfaceTrackingActive ? "Temporary" : "Inactive")
                Button("Refine fit with designated scalp mask") {
                    controller.refineScalpSurface()
                }.disabled(!controller.canRefineSurface)
                Toggle("Optional manual correspondence", isOn: $manualLandmarks)
                Text("Marker-free facial features establish a pose. LiDAR matching may continue briefly during partial occlusion, but losing tracking hides the overlay.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Path depth · illustration") {
                if !controller.study.trajectories.isEmpty {
                    Picker("Trajectory", selection: Binding(
                        get: { controller.selectedIndex },
                        set: { controller.selectTrajectory($0) })) {
                            ForEach(controller.study.trajectories.indices, id: \.self) { index in
                                Text(controller.study.trajectories[index].name).tag(index)
                            }
                        }
                    if let path = controller.activeTrajectory {
                        LabeledContent("Path length", value: String(format: "%.1f mm", RustBridge.pathLengthMm(path)))
                        LabeledContent("Displayed depth", value: String(format: "%.1f mm", controller.depthMm))
                        Slider(value: Binding(get: { controller.depthMm },
                                              set: { controller.setDepth($0) }),
                               in: 0...max(1, path.lengthMm), step: 0.5)
                    }
                    DisclosureGroup("Edit research path coordinates", isExpanded: $editingPath) {
                        coordinateEditor(entry: true)
                        coordinateEditor(entry: false)
                    }
                } else {
                    Text("Transfer a study before exploring a trajectory.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Phantom diagnostics") {
                Toggle("Testing only a nonhuman phantom", isOn: $controller.phantomOnlyAcknowledged)
                Button("Record LiDAR point statistics") { controller.recordPhantomDiagnostic() }
                    .disabled(!controller.phantomOnlyAcknowledged)
                if let quality = controller.lastPhantomDiagnostic {
                    LabeledContent("Samples", value: "\(quality.sampleCount)")
                    LabeledContent("Cloud spread", value: String(format: "%.1f mm", quality.spatialSpreadMm))
                    LabeledContent("Median radius", value: String(format: "%.1f mm", quality.medianRadiusMm))
                }
                Text("These values are not depth-accuracy or clinical registration measurements.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Session status") {
                Text(controller.status).font(.footnote).textSelection(.enabled)
            }
        }
    }

    private func coordinateEditor(entry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry ? "Entry (mm)" : "End point (mm)")
                .font(.subheadline.weight(.semibold))
            ForEach(0..<3, id: \.self) { axis in
                HStack {
                    Text(["Right", "Superior", "Anterior"][axis])
                    Spacer()
                    Text(String(format: "%.0f", controller.coordinate(entry: entry, axis: axis)))
                        .monospacedDigit()
                    Stepper("Adjust", value: Binding(
                        get: { controller.coordinate(entry: entry, axis: axis) },
                        set: { controller.setCoordinate(entry: entry, axis: axis, value: $0) }),
                            in: -180...180, step: 1)
                        .labelsHidden()
                }
            }
        }.padding(.vertical, 8)
    }
}

private struct ValidationWorkspace: View {
    @ObservedObject var controller: ARHeadController
    @ObservedObject var imaging: MRIPlanningModel

    var body: some View {
        List {
            Section {
                Label("Research / education only", systemImage: "exclamationmark.shield.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("No clinical validation. Do not use for EVD placement, clinical planning, patient identification, or instrument navigation. Fit residuals do not measure intracranial accuracy.")
                    .font(.subheadline)
            }
            Section("MRI data") {
                LabeledContent("Source", value: imaging.volume.isSynthetic ? "Synthetic phantom" : "Imported")
                LabeledContent("Voxel grid", value: imaging.volume.dimensions.map(String.init).joined(separator: " × "))
                LabeledContent("Landmarks", value: "\(imaging.landmarks.count)")
                LabeledContent("Candidate paths", value: "\(imaging.candidates.count)")
                LabeledContent("ROI", value: imaging.mask == nil ? "Not imported" : "External mask")
            }
            Section("Tracking / registration") {
                LabeledContent("Head tracking", value: controller.naturalHeadBound ? "Experimental fit" : "Not registered")
                LabeledContent("LiDAR", value: controller.lidarSupported ? "Supported" : "Not verified")
                LabeledContent("Facial features", value: "\(controller.naturalFeatureCount)")
                errorMetric("Landmark fit RMSE", controller.registration?.landmarkRMSEmeters)
                errorMetric("Natural fit RMSE", controller.naturalFitRMSEmeters)
                errorMetric("Scalp ICP RMSE", controller.surfaceFitRMSEmeters)
                errorMetric("Motion ICP RMSE", controller.surfaceMotionRMSEmeters)
                errorMetric("Held-out surface residual", controller.heldOutSurfaceResidualMeters)
                Text("Values reflect fitting residuals, not independent intracranial target accuracy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Validation to complete") {
                Label("Physical mannequin / phantom testing", systemImage: "ruler")
                Label("Head turns and prolonged occlusion", systemImage: "arrow.triangle.2.circlepath")
                Label("Scan orientation and distortion verification", systemImage: "square.3.layers.3d")
                Label("Independent target registration error", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Label("Clinical device risk assessment", systemImage: "cross.vial")
            }
        }
    }

    private func errorMetric(_ label: String, _ value: Double?) -> some View {
        LabeledContent(label, value: value.map { String(format: "%.1f mm", $0 * 1000) } ?? "Unavailable")
    }
}
