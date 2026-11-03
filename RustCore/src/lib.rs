//! Portable geometry primitives used to validate the planned Swift/Rust boundary.
//! Research visualization only; NOT for patient care or clinical navigation.

/// Straight-line distance, in millimeters, between two points expressed in
/// the same calibrated image coordinate system. Returns NaN if an input is
/// not finite. This does not establish anatomical or registration accuracy.
#[must_use]
pub fn distance_mm(a: [f64; 3], b: [f64; 3]) -> f64 {
    if a.iter().chain(b.iter()).any(|v| !v.is_finite()) {
        return f64::NAN;
    }
    let d = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    d[0].hypot(d[1]).hypot(d[2])
}

/// C ABI for an eventual native Swift bridge; currently not linked into Xcode.
/// Coordinates and return value are in millimeters.
#[no_mangle]
pub extern "C" fn neuroar_distance_mm(
    ax: f64, ay: f64, az: f64,
    bx: f64, by: f64, bz: f64,
) -> f64 {
    distance_mm([ax, ay, az], [bx, by, bz])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geometry_distance_is_metric() {
        assert!((distance_mm([0.0, 0.0, 0.0], [3.0, 4.0, 12.0]) - 13.0).abs() < 1e-12);
    }

    #[test]
    fn large_close_coordinates_do_not_overflow() {
        assert!((distance_mm([1_000_000.0, -200.0, 20.0], [1_000_003.0, -196.0, 32.0]) - 13.0).abs() < 1e-12);
    }

    #[test]
    fn rejects_nans_and_infinities() {
        assert!(distance_mm([0.0, f64::NAN, 0.0], [0.0; 3]).is_nan());
        assert!(neuroar_distance_mm(0.0, 0.0, 0.0, f64::INFINITY, 0.0, 0.0).is_nan());
    }
}
