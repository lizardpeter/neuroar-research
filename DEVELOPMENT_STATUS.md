# NeuroAR v0.9 development status — November 3, 2026

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
- **Marker-free natural head tracker**: Vision rear-camera face detection and
  left/right eye, nose and lip features, per-feature LiDAR 3D unprojection,
  automatic match to explicitly MRI-annotated facial landmarks, and repeated
  head-motion estimates. A multi-face frame is rejected. On loss/ambiguity,
  hide overlay immediately and clear registration on sustained loss.
- No printed sticker/marker or ARKit image-anchor binding in the active flow.
  Independent testing against physical phantom reference measurements remains required.
- Rust static library prebuilt and linked into the Xcode iOS target via a
  native build phase; SwiftUI calls an exported Rust path-length function.
- Synthetic-only on-device sensor diagnostic UI, without exporting raw images.
- Documented phantom testing protocol and fail-closed tracking behavior.

## Validation so far

- `swift test --package-path GeometryCore` — **41 tests passed** on Linux, including natural-feature tests.
- Swift iOS files pass syntax parsing; Xcode project parses as OpenStep plist.
- **New Xcode iOS simulator CI, Rust linking, and physical ARKit behavior
  require GitHub macOS and actual hardware testing. Do not assume they pass.**
- No real iPhone LiDAR recording, quantified sensor accuracy, or patient/head
  movement test has been completed in this environment.

## Still missing

- DICOM JPEG-LS, JPEG2000 and enhanced multiframe images (require native codecs).
- Automatic segmentation of true scalp, vasculature, skull, ventricles.
- Automatic MRI **facial feature extraction** and patient-specific identity matching (current MRI points require manual annotation).
- Verified marker-free 3D head motion tracking over diverse angles and occlusion; robust scalp-only tracking with face out of view is not implemented.
- Calibration of Vision orientation/landmark points and measured accuracy on a real LiDAR iPhone.
- Independent target registration error against ground-truth phantom fiducials,
  distortion/latency studies, clinical risk management or regulatory review.
