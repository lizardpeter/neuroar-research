# Marker-free head tracking (research prototype)

**No printed markers or physical fiducials required.** This uses Vision facial-feature detections in the rear camera, calibrated ARKit LiDAR depth, and the current ARKit world-camera pose. It does **not** verify the subject's identity, guarantee millimetric accuracy, or support any clinical navigation or instrument guidance.

## Workflow

1. Import a full-head MRI in the planner. Use the MRI crosshair to annotate at least three corresponding visible facial features; **four are strongly recommended**. Use exact annotation labels: `LeftEyeCenter`, `RightEyeCenter`, `NoseTip`, `MouthCenter`. These are *natural anatomical landmarks in the image*, not stickers applied to the head.
2. Transfer the study into Live AR. With normal ARKit camera tracking, point the **rear camera** at a single visible face. Vision detects the face and natural 2D feature regions. For each, the app samples high-confidence LiDAR depth and reconstructs world-coordinate 3D observations.
3. A rigid MRI-to-world fit is accepted only when matching MRI labels and camera features provide enough noncollinear correspondences and the demonstration residual guards pass. If they do not, the overlay remains hidden.
4. Subsequent frames estimate head-motion transformations from baseline facial geometry to new 3D observations; the MRI overlay follows **the head rather than the world anchor**. Depth/face/ARKit tracking loss hides it. Prolonged tracking loss discards the registration.
5. Optional point-to-point ICP can refine the pose if an external, explicitly designated MRI scalp segmentation exists. This is not a validated or complete anatomical registration algorithm.

## Known limitations and safety

- Vision eye/lip polygons and the depth-derived nose prominence are **approximations** of physical anatomical landmark locations. The MRI points may not exactly correspond. Coarse depth errors, hair, expression, facial hair, motion blur, or glasses can cause mismatches.
- ARKit `.sceneDepth` is rear-camera LiDAR, and Vision face observations are **not** ARKit `ARFaceAnchor`s. ARKit's front TrueDepth face-tracking API cannot track a third person's face in the rear camera.
- The current camera implementation targets portrait operation and uses EXIF `.right` to orient rear-camera pixels for Vision before unrotating normalized points to the LiDAR sensor pixel grid. This must be tested/calibrated on the actual device, including camera/view aspect ratio and depth interpolation.
- One visible face only. If two faces are detected, the tracker rejects that frame to avoid silently switching subjects. If facial features are obscured or the head turns away, the overlay hides; **360-degree scalp-only motion tracking is not established**.
- Initial registration requires manual *MRI* feature annotation. This release does **not** automatically find a nose/eyes in the MRI, match patient identity, or guarantee a correct match to the physical head.
- Low fitted landmark error/ICP error is **not target registration error (TRE)**. No on-device clinical validation, photogrammetry, latency test, movement-phantom ground truth, or human safety study has been completed.
- A real research study should use a nonhuman phantom and external, independent reference measurements, and record accuracy and failure rates for each pose, distance, lighting condition, occlusion and expression.

## Developer checks

- `swift test --package-path GeometryCore` tests natural landmark naming, unit conversion, correspondence geometry, bad landmarks and excessive motion on synthetic data.
- Public GitHub Actions builds the complete Swift/ARKit application on macOS. No iOS device or LiDAR hardware is available on CI, so CI success alone proves only compilation.
