# NeuroAR iOS native design (v0.11)

This is a **research-only** MRI and LiDAR visualization prototype. The UI must
never imply that alignment is suitable for physical EVD placement or clinical
navigation. A visually convincing overlay can be anatomically wrong.

## Navigation / information hierarchy

- **Study:** Standard NavigationStack and native tab bar; image import from a
  Menu, full-width axial image and two smaller companion views; candidate
  trajectory, annotations, 3D preview, and export controls beneath.
- **Live AR:** The camera fills the workspace; floating tracking status and
  path-depth controls use a small Liquid Glass surface on iOS 26. All detailed
  controls live in a native sheet with medium/large detents. The live HUD
  explicitly states that the visualization is not for EVD/surgery.
- **Validation:** Separate List with scan provenance and registration residuals,
  highlighting the evidence that is still missing. Residuals are **not** TRE.

## Liquid Glass and platform support

Apple's modern iOS design treats glass as an interactive/navigation layer. We
therefore use the system's `TabView`, `NavigationStack`, `toolbar`, `Menu`, `Form`,
`List`, `.sheet` and native button styles. `glassEffect` is limited to two
foreground Live AR HUD elements, guarded by `#available(iOS 26, *)`. On older
systems, the HUD uses `.regularMaterial`. Dense image cards use semantic
`systemGroupedBackground` / `secondarySystemGroupedBackground` instead of
semi-transparent white. The application does **not** force a global dark mode;
the camera view alone uses a dark palette for stable contrast.

## State consistency and data provenance

- Switching away from Live AR or backgrounding pauses the camera and invalidates
  world-space registration. Reentering always starts a fresh AR session.
- A dedicated freshness gate checks timestamps independently of camera status.
- Reusing a named MRI landmark replaces the prior location rather than
  creating duplicate natural correspondences.
- Orthogonal MRI raster caching is keyed to volume/mask revisions, cursor and
  contrast-window values; changing only the path-depth slider does not trigger
  image resampling.

## QA required on actual iPhone

1. iOS 26 native Liquid Glass, older iOS material fallback, light/dark mode,
   large Dynamic Type, Reduce Transparency and Reduce Motion.
2. VoiceOver reading order of status and depth controls; 44-point minimum
   touch areas; portrait safe areas and Home indicator/tab bar interactions.
3. No camera capture when Live AR is inactive, screen locked or app backgrounded;
   no old registration on return.
4. Different camera models, LiDAR availability, landscape rotation limitations,
   scene interruptions, multiple visible faces and partial occlusion.
5. Independent synthetic-phantom pose/target error across head motion and phone
   motion, including loss-of-tracking events. Not yet performed.

**No clinical accuracy or device compliance is claimed.**
