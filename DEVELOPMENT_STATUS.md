# NeuroAR v0.8 development status — November 3, 2026

**Research-only. Not a medical device.** MRI-to-head overlays and manually
sketched trajectories must not guide physical procedures.

## Implemented locally

- Direct import of `.nii.gz` via zlib GZIP with CRC check, bounded output and
  rejection of truncated/trailing members; plus existing `.nii` NIfTI-1.
- Single-frame conventional grayscale DICOM RLE Lossless decoder and Part 10
  encapsulated pixel extraction, alongside preexisting uncompressed DICOM.
- Landmark-seeded trimmed point-to-point ICP with spatial bins, max distance,
  outlier trimming, conservative movement guard and a *separate* held-out point.
- Single-frame LiDAR point cloud extraction for ICP, with confidence, crop and
  3D landmark vicinity filtering.
- Marker-following AR prototype using a generated 50 mm reference-image anchor;
  overlay hidden on marker loss and when MRI has no bound head marker.
- Rust static library prebuilt and linked into the Xcode iOS target via a
  native build phase; SwiftUI calls an exported Rust path-length function.
- Synthetic-only on-device sensor diagnostic UI, without exporting raw images.
- Documented phantom testing protocol and fail-closed tracking behavior.

## Validation so far

- `swift test --package-path GeometryCore` — **35 tests passed** on Linux.
- Swift iOS files pass syntax parsing; Xcode project parses as OpenStep plist.
- **New Xcode iOS simulator CI, Rust linking, and physical ARKit behavior
  require GitHub macOS and actual hardware testing. Do not assume they pass.**
- No real iPhone LiDAR recording, quantified sensor accuracy, or patient/head
  movement test has been completed in this environment.

## Still missing

- DICOM JPEG-LS, JPEG2000 and enhanced multiframe images (require native codecs).
- Automatic segmentation of true scalp, vasculature, skull, ventricles.
- Robust markerless identification and registration of MRI to a real head.
- Image anchor / scalp motion tracking verified on a real LiDAR iPhone.
- Independent target registration error against ground-truth phantom fiducials,
  distortion/latency studies, clinical risk management or regulatory review.
