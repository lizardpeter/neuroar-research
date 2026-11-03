import SwiftUI
import ARKit
import RealityKit
import UniformTypeIdentifiers
import GeometryCore

struct HeadARView: UIViewRepresentable {
    @ObservedObject var controller: ARHeadController
    func makeCoordinator() -> Coordinator { Coordinator(controller:controller) }
    class Coordinator {
        let controller:ARHeadController
        init(controller:ARHeadController) { self.controller=controller }
    }
    static func dismantleUIView(_ uiView:ARView,coordinator:Coordinator) {
        coordinator.controller.disconnect(from:uiView)
    }
    func makeUIView(context: Context) -> ARView {
        let view=ARView(frame:.zero)
        controller.connect(to:view)
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var controller = ARHeadController()
    @StateObject private var imaging = MRIPlanningModel()
    @State private var workspace = 0
    @State private var importingStudy=false
    @State private var importingMesh=false
    @State private var showEditor=false
    private let accent=Color(red:0.20,green:0.85,blue:0.90)

    var body: some View {
        GeometryReader { shell in
            VStack(spacing:0) {
                header
                Picker("Workspace",selection:$workspace) {
                    Text("MRI PLANNER").tag(0)
                    Text("LIVE AR").tag(1)
                }
                .pickerStyle(.segmented).padding(.horizontal,14).padding(.bottom,8)
                if workspace == 0 {
                    MRIPlanningView(model:imaging,arController:controller,onOpenAR:{ workspace=1 })
                } else {
                ZStack(alignment:.top) {
                    GeometryReader { camera in
                        HeadARView(controller:controller)
                            .ignoresSafeArea(edges:.horizontal)
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { gesture in
                                controller.captureLandmark(at:gesture.location,viewportSize:camera.size)
                            })
                        if controller.registration == nil {
                            VStack(spacing:6) {
                                Text("LANDMARK CAPTURE").font(.caption).tracking(1.7).bold()
                                if let next=controller.nextLandmark {
                                    Text("Tap the physical location: \(next.name)")
                                        .font(.subheadline).multilineTextAlignment(.center)
                                } else {
                                    Text("Fitting landmark correspondence…").font(.subheadline)
                                }
                                Text("\(controller.capturedPoints.count) / \(controller.study.landmarks.count)")
                                    .font(.caption.monospacedDigit())
                            }
                            .padding(12).frame(maxWidth:.infinity)
                            .background(.black.opacity(0.72),in:RoundedRectangle(cornerRadius:14))
                            .foregroundStyle(.white)
                            .padding(12)
                            .allowsHitTesting(false)
                        }
                    }
                    VStack {
                        Spacer()
                        HStack {
                            Text("RESEARCH / EDUCATION ONLY · NOT FOR SURGICAL GUIDANCE")
                                .font(.system(size:10,weight:.bold,design:.monospaced))
                                .multilineTextAlignment(.center)
                        }
                        .padding(10).frame(maxWidth:.infinity)
                        .background(Color.red.opacity(0.92))
                    }
                    .allowsHitTesting(false)
                }
                .frame(height:max(230,shell.size.height*0.43))
                controlPanel
                }
            }
            .background(Color(red:0.04,green:0.07,blue:0.1))
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .onChange(of:imaging.volumeRevision) { _, _ in
            controller.invalidatePlanningLink()
        }
        .fileImporter(isPresented:$importingStudy,allowedContentTypes:[.json]) { result in
            if case let .success(url)=result { controller.importStudy(url:url) }
        }
        .fileImporter(isPresented:$importingMesh,allowedContentTypes:[UTType(filenameExtension:"usdz") ?? .data]) { result in
            if case let .success(url)=result { controller.importMesh(url:url) }
        }
    }

    private var header: some View {
        HStack(spacing:12) {
            Image(systemName:"brain.head.profile").font(.title2).foregroundStyle(accent)
            VStack(alignment:.leading,spacing:1) {
                Text("NEURO / AR").font(.headline).tracking(1.7)
                Text("MRI SPACE · LIDAR REGISTRATION · TRAJECTORY LAB")
                    .font(.system(size:9,weight:.medium,design:.monospaced))
                    .foregroundStyle(.gray)
            }
            Spacer()
            Circle().fill(controller.trackingIsNormal ? .green : .orange).frame(width:9,height:9)
        }
        .padding(.horizontal,16).padding(.vertical,11)
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Text(controller.status).font(.caption).foregroundStyle(.cyan)
                    .frame(maxWidth:.infinity,alignment:.leading)
                HStack(spacing:8) {
                    Button("Import study JSON") { importingStudy=true }
                    Button("Import anatomy USDZ") { importingMesh=true }
                    Button("Reset") { controller.clearRegistration() }
                }
                .buttonStyle(CompactButtonStyle())

                if let result=controller.registration {
                    HStack(spacing:18) {
                        metric("LANDMARK FIT",String(format:"%.1f mm",result.landmarkRMSEmeters*1000))
                        metric("WORST RESIDUAL",String(format:"%.1f mm",result.maxLandmarkResidualMeters*1000))
                        metric("FIT POINTS",String(result.count))
                        metric("HOLD-OUT",controller.heldOutSurfaceResidualMeters.map { String(format:"%.1f mm",$0*1000) } ?? "Not measured")
                    }
                    Text("A fourth or later landmark reserves the final surface point as an independent check. Neither fit nor held-out surface residual measures intracranial target accuracy.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Divider().overlay(Color.gray.opacity(0.3))
                Text(controller.study.title).font(.subheadline.bold())
                HStack {
                    Text("Trajectory explorer").font(.headline)
                    Spacer()
                    Text("MRI coordinates / mm").font(.caption2).foregroundStyle(.gray)
                }
                if !controller.study.trajectories.isEmpty {
                    Picker("Trajectory",selection:Binding(get:{controller.selectedIndex},set:{controller.selectTrajectory($0)})) {
                        ForEach(controller.study.trajectories.indices,id:\.self) { idx in
                            Text(controller.study.trajectories[idx].name).tag(idx)
                        }
                    }
                    .tint(accent)
                    if let path=controller.activeTrajectory {
                        HStack {
                            Text("Displayed depth").foregroundStyle(.white)
                            Spacer()
                            Text(String(format:"%.1f / %.1f mm",controller.depthMm,path.lengthMm))
                                .monospacedDigit().foregroundStyle(accent)
                        }
                        Slider(value:Binding(get:{controller.depthMm},set:{controller.setDepth($0)}),
                               in:0...max(1,path.lengthMm),step:0.5)
                            .tint(accent)
                        Text("Yellow: displayed path depth · Gray: remainder · Purple: study-defined end point")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                    DisclosureGroup("Edit synthetic / imported path coordinates",isExpanded:$showEditor) {
                        coordinateEditor(entry:true)
                        coordinateEditor(entry:false)
                    }
                    .font(.caption)
                    .tint(accent)
                }
                Divider()
                Text("Validation status").font(.caption.bold()).foregroundStyle(.orange)
                Text(controller.plannerLinked
                     ? "Current MRI planning study and selected coarse 3D surfaces are linked. Landmark alignment is manually fitted; image-target accuracy, movement tracking and suitability for EVD navigation have NOT been validated."
                     : "Only the synthetic phantom or separately imported JSON/USDZ study is loaded. Open MRI Planner to explicitly transfer an MRI study and its landmarks. No automatic head registration or clinical trajectory validation.")
                    .font(.caption2).foregroundStyle(.gray)
            }
            .padding(16)
        }
    }

    private func metric(_ label:String,_ value:String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(label).font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(.gray)
            Text(value).font(.subheadline.bold().monospacedDigit())
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }

    private func coordinateEditor(entry:Bool) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text(entry ? "Entry (mm)" : "End point (mm)").font(.subheadline.bold())
            ForEach(0..<3,id:\.self) { axis in
                HStack(spacing:10) {
                    Text(["X right","Y superior","Z anterior"][axis])
                        .frame(width:88,alignment:.leading)
                    Spacer()
                    Text(String(format:"%.0f mm",controller.coordinate(entry:entry,axis:axis)))
                        .monospacedDigit()
                    Stepper("",value:Binding(
                        get:{controller.coordinate(entry:entry,axis:axis)},
                        set:{controller.setCoordinate(entry:entry,axis:axis,value:$0)}),
                            in:-180...180,step:1)
                        .labelsHidden()
                }
            }
        }.padding(.top,8)
    }
}

struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size:11,weight:.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal,9).padding(.vertical,10)
            .frame(maxWidth:.infinity)
            .background(Color(red:0.14,green:0.23,blue:0.28).opacity(configuration.isPressed ? 0.6 : 1),
                        in:RoundedRectangle(cornerRadius:8))
    }
}
