#ifndef NEUROAR_CORE_H
#define NEUROAR_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// All coordinates are millimeters in the same image coordinate frame.
// Returns NaN for non-finite coordinates. Not for clinical navigation.
double neuroar_distance_mm(
    double ax, double ay, double az,
    double bx, double by, double bz
);

#ifdef __cplusplus
}
#endif

#endif
