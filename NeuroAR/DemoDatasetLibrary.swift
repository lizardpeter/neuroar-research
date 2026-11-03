import Foundation
import CryptoKit
import GeometryCore

/// User-initiated downloads only. Public research examples are never shipped
/// inside the app binary, and scans imported by users are never uploaded.
struct DemoDataset: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let sha256: String
    let source: String
    var url: URL {
        URL(string: "https://github.com/Slicer/SlicerTestingData/releases/download/SHA256/" + sha256)!
    }

    static let samples: [DemoDataset] = [
        .init(id: "ct-brain", title: "Head CT", detail: "CT–MR Brain pair · bone and scalp",
              sha256: "6a5b6caccb76576a863beb095e3bfb910c50ca78f4c9bf043aa42f976cfa53d1",
              source: "3D Slicer / SlicerTestingData"),
        .init(id: "mr-brain-t1", title: "Head MRI · T1",
              detail: "CT–MR Brain pair · T1-weighted reference",
              sha256: "2da3f655ed20356ee8cdf32aa0f8f9420385de4b6e407d28e67f9974d7ce1593",
              source: "3D Slicer / SlicerTestingData"),
        .init(id: "mr-brain-t2", title: "Head MRI · T2",
              detail: "CT–MR Brain pair · T2-weighted reference",
              sha256: "fa1fe5910a69182f2b03c0150d8151ac6c75df986449fb5a6c5ae67141e0f5e7",
              source: "3D Slicer / SlicerTestingData"),
        .init(id: "mr-head", title: "Full head MRI",
              detail: "Independent Slicer MR-head sample · NOT CT–MR pair",
              sha256: "cc211f0dfd9a05ca3841ce1141b292898b2dd2d3f08286affadf823a7e58df93",
              source: "3D Slicer / SlicerTestingData"),
        .init(id: "cbct-head", title: "Head cone-beam CT",
              detail: "CBCT–MR Head pair · independent from CT–MR Brain",
              sha256: "4ce7aa75278b5a7b757ed0c8d7a6b3caccfc3e2973b020532456dbc8f3def7db",
              source: "3D Slicer / SlicerTestingData"),
        .init(id: "cbct-mr", title: "Head MRI · CBCT pair",
              detail: "CBCT–MR Head pair · independent from CT–MR Brain",
              sha256: "b5e9f8afac58d6eb0e0d63d059616c25a98e0beb80f3108410b15260a6817842",
              source: "3D Slicer / SlicerTestingData")
    ]
}

enum DemoDatasetLoader {
    /// Downloads to the iOS cache (not iCloud), validates the upstream
    /// content-addressed SHA-256, then decodes on a background executor.
    static func load(_ item: DemoDataset) async throws -> VoxelVolume {
        let fm = FileManager.default
        let folder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuroAR-Public-Examples", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = folder.appendingPathComponent(item.sha256 + ".nrrd")
        if !fm.fileExists(atPath: saved.path) {
            let (downloaded, response) = try await URLSession.shared.download(from: item.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ImagingError.unsupported("Public dataset download was unavailable")
            }
            let fileSize = (try? fm.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.intValue ?? 0
            guard fileSize > 0, fileSize <= NRRDReader.maximumSourceBytes else {
                throw ImagingError.tooLarge
            }
            let bytes = try Data(contentsOf: downloaded, options: [.mappedIfSafe])
            guard verify(bytes, checksum: item.sha256) else {
                throw ImagingError.invalidPayload
            }
            try fm.moveItem(at: downloaded, to: saved)
        }
        let bytes = try Data(contentsOf: saved, options: [.mappedIfSafe])
        guard bytes.count <= NRRDReader.maximumSourceBytes,
              verify(bytes, checksum: item.sha256) else {
            try? fm.removeItem(at: saved)
            throw ImagingError.invalidPayload
        }
        return try NRRDReader.load(bytes)
    }

    private static func verify(_ data: Data, checksum: String) -> Bool {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == checksum
    }
}
