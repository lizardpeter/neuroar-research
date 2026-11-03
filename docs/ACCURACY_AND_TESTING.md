# Validation protocol for synthetic/nonhuman phantoms

## Never infer clinical accuracy from AR visual alignment

Landmark fit RMS, ICP inlier RMS, and LiDAR point-cloud spread are **not**
independently measured intracranial target registration error (TRE). The
research prototype makes no patient-use claim. Do not place instruments,
drill, or perform procedures using its trajectories.

## Reproducible bench setup

1. Use a rigid, nonhuman phantom with a separately documented MRI/CT model and
   independently measured physical reference points. No patient data.
2. Record model revision, iPhone/iPad model, iOS version, camera configuration,
   lighting, sensor distance, ARKit tracking state, and marker dimensions.
3. Verify outer printed marker width is **50.0 mm**; measure with a ruler at
   printing scale 100%. Fix it to the rigid phantom, not elastic skin.
4. Register using preassigned visible model-to-physical landmarks. Reserve
   *different* points not used in fitting or ICP refinement for independent
   TRE. Measure each point in both physical and MRI coordinates using a separate
   calibrated method.
5. At each phantom pose, compute distance between transformed image point and
   held-out physical reference. Report median, 95th percentile, maximum error,
   test count, and missing/failed-tracking percentage, in millimeters.
6. Deliberately hide the marker, move the phantom, temporarily occlude the
   camera, rotate the phone, pause/resume AR, and cause relocalization; confirm
   the overlay **disappears** when tracking is not confirmed. Record any stale
   overlay frames as failure.
7. Repeat across distances, orientations, different devices and scans.
   Evaluate motion latency separately with independent timestamped ground truth.

## Privacy and failure reporting

The in-app diagnostics include counts and spatial spread only and are not
intended as ground truth. Do not upload phantom/camera recordings automatically
or include any identifiable human images. Never place patient DICOM data in
GitHub Actions, test archives, or issue attachments.

If the app is to be used for anything other than research visualization, a
formal medical-device quality, validation and regulatory program would be
required. No acceptance threshold in this document constitutes certification.
