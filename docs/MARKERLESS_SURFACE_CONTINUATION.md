# Natural-head tracking: short-term LiDAR surface continuation

**NeuroAR Research / experimental only. Not for patient care, needle navigation, EVD insertion, or surgical guidance.**

## Why this path exists

The initial rear-camera Vision + LiDAR system required three or more visible facial features on every accepted frame. That produces a hard failure as the face turns slightly away or becomes transiently occluded. Now an **already established** natural-face MRI-to-head correspondence may be continued using consecutive bounded LiDAR head-surface point clouds, without an attached marker.

## Sensor and geometry pipeline

1. With a single clear face in view, Vision obtains natural facial feature regions; ARKit's color-camera intrinsics and high-confidence `sceneDepth` convert them into world-space 3D positions.
2. A non-collinear correspondence to **already annotated** MRI facial features establishes an experimental initial rigid pose. This does **not** independently prove subject identity or anatomical accuracy.
3. Save a bounded LiDAR face-region cloud and its centroid, in ARKit world-space meters.
4. If fewer than three facial features are available, search only within a 160 mm radius of the most recently accepted face/head cloud centroid. This is a spatial crop, **not anatomical segmentation**. Any background samples are treated as potentially unsafe.
5. On a background queue, run incremental trimmed rigid ICP against the previous accepted cloud. The geometry engine rejects insufficient samples, flat or collapsed geometry, large motion, low overlap and large fitted residuals.
6. Apply the resulting world-space delta to the current MRI overlay **only** if it is still recent, the previous reference has not changed, ARKit tracking is normal, and the initial facial correspondence is no more than 1.8 seconds old.
7. Reject or hide the overlay on failed matches, stale data, ARKit interruptions, multi-face ambiguity or prolonged loss. Reacquire the face to resume.

## What this does not yet solve

- It **does not** automatically identify facial landmarks *inside the MRI*. The MRI must contain an appropriately oriented face and the corresponding anatomical points must currently be annotated in the planner.
- It does **not** prove correct MRI-to-head alignment, patient identity, or safe EVD trajectory. ICP's fitted residual is not independent registration error.
- LiDAR can be noisy around hair, dark or reflective surfaces, edges, changing facial expressions and glasses. The predicted crop can accidentally include the background or another nearby head.
- A front/side face point cloud is not a full 360-degree head model. Short-term surface continuation is deliberately capped and cannot ensure stable tracking through full head rotation.
- Real iPhone camera/depth calibration, Vision pixel rotation and orientation, time synchronization, motion latency, power consumption and physical phantom ground truth are **unverified**.
- No deep-learning MRI face extraction or validated scalp segmentation is integrated. Explicit mask imports remain separate.

## Testing protocol to run after TestFlight signing works

Use a **nonhuman geometric phantom** with independently measured landmarks. Vary lighting, viewing distance, phone movement, phantom head rotation, partial occlusion and proximity to nearby surfaces. Record independent ground-truth target registration error, frame latency, dropouts, false locks and reacquisition time. The code's internal residuals, test-case pass rate and sample spatial spread do **not** measure physical anatomical accuracy.

A passing iOS Simulator build verifies compilation only. Simulator does not supply real LiDAR scene depth. Do not enable live MRI overlay for real patient care.
