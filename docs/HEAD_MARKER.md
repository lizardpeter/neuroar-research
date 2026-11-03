# Experimental head-following marker (NOT for surgery)

1. Print `NeuroAR/Assets.xcassets/HeadMarker.imageset/HeadMarker.png` at **exactly 50.0 × 50.0 mm**, including its outer white border. Disable fit-to-page and printer scaling.
2. Verify its outer square dimensions with a ruler; reject a differently sized print.
3. Attach the flat marker firmly to a **nonmoving phantom head**, avoiding reflective film, folds, and occlusion.
4. In NeuroAR, obtain a landmark-registered synthetic / phantom MRI study. Wait until the marker shows as tracked, then tap **Bind to visible marker**.
5. Move the phantom slowly while keeping the marker visible. The overlay will hide if marker tracking is lost.

A tracked planar marker is a demonstration aid. Its pose can be noisy, skin moves, printer scaling may be wrong, camera relocalization can invalidate world coordinates, and **this marker does not establish target registration error or surgical accuracy**.

The app cannot validate an actual physical iPhone/LiDAR sensor from GitHub Actions. Physical-device test recordings must be made locally using an explicitly consented **synthetic mannequin/phantom**, then assessed against separately measured ground truth.
