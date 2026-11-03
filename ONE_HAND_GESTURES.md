# NeuroAR: one-free-hand interaction and calibration

**This is experimental, research-only AR.** No hand pose, relative anatomical
volume movement, or LiDAR anchor from this workflow is medical navigation.

## Using one hand (the rear camera)

The app uses the rear-facing ARKit camera for BOTH world tracking and Apple
Vision hand detection. Hold the phone with one hand (or put it on a stand),
place a virtual CT/MRI volume using a surface raycast, then move your **other**
hand inside the rear camera field of view. A camera looking at a table will
not see a hand behind the phone.

Hand tracking is ON by default in the Demo AR tab. It runs before surface
placement so that a missing hand is not confused with a missing AR anchor.

**Modes (all require only one visible hand):**

- **Smart:** pinch thumb and index to clutch/translate; move the hand
  toward/away from camera to change its apparent palm size (a monocular
  **scale proxy**, not a depth measurement); twist wrist to roll; hold an
  open palm and move left/right/up/down to orbit.
- **Move:** pinch and move left/right/up/down to translate, without resizing.
- **Rotate:** pinch and move to orbit, twist wrist to roll.
- **Scale:** pinch and move UP to enlarge or DOWN to shrink. This is a
  reliable one-hand alternative when apparent hand size is unstable.

The segmented mode selector is visible directly on the AR screen. Touch
gestures always work regardless of hand detection or lighting.

## Live debugging and response

- **Green hand indicator / ring:** hand found; the ring is an approximate
  camera-normalized 2D position, not a calibrated world-space location.
- **No hand:** one or more joints could not be detected confidently. Move
  the whole hand into the rear camera field of view, show wrist and fingers,
  improve illumination and contrast, move slower, or remove motion blur.
- **Hand found but no action:** make thumb/index pinch or open palm, wait
  for two detections (anti-false-positive clutch), and confirm a world
  anchor has been placed.
- **Confidence / gap / rate / processing time:** the controls panel displays
  these values to separate failure of recognition from high inference latency.
- **Loss / reclutch:** when the hand disappears, previous motion baselines
  are discarded to prevent sudden multi-centimeter jumps on reacquisition.
- **One background request at a time:** no accumulating queue, uses one-hand
  Vision maximum, ~13 Hz request ceiling, and slower processing at serious
  device thermal states.

## Physical acceptance tests (required, cannot be completed in CI)

1. Open Demo AR and before placing the model, show your free hand to the
   rear camera. Hand status must turn to detected. Confirm confidence,
   pinch ratio, and recognition time vary plausibly.
2. Scan a table, place the AR anchor, select Move. Pinch and move along
   X/Y. Release; the anatomy should stop, with no jump on clutch release.
3. Choose Rotate. Pinch and trace a horizontal and then vertical gesture;
   wrist twist should roll. No second hand required.
4. Choose Scale. Pinch and move up/down. Verify both growth and shrinkage.
5. Try Smart. Pinch translates; open palm rotates; changing apparent
   palm size during a pinch should resize. This is less deterministic than
   dedicated modes.
6. Try hand occlusion, low light and quick motion. The model must not
   jump when hands disappear and reappear; the anchor must remain fixed.
7. Compare detection fps, Vision processing time, AR fps/thermal behavior,
   and actual tablet-relative drift with hand tracking toggled on/off.
8. Confirm leaving the Demo AR tab or backgrounding the app stops camera
   and GPU hand processing.

## Current bounds and future tracking engines

Apple's built-in Vision hand pose returns **2D** joints and confidence,
not a true spatial pose or range for the hand. A finger appearing larger
on screen can indicate moving closer, but perspective, wrist articulation,
and partial occlusion can produce false scale changes.

For a later performance/quality comparison, consider Google MediaPipe Hand
Landmarker (21 landmarks, approximate world-hand landmarks and temporal
tracking). Its world-landmarks coordinates are relative to the hand center,
**not** an automatically registered world-space hand position and not a
replacement for LiDAR-based AR anchoring.

Before changing runtime dependencies, measure actual Vision latency and
recognition reliability on the user's physical iPhone. Do not claim that
a different algorithm is automatically faster or more accurate.
