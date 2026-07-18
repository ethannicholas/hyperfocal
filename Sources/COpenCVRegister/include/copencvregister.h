// OpenCV homography registration, exposed to the *macOS* engine build for the
// Phase 1.5 A/B (OpenCV vs Vision) — see Docs/cross-platform-plan.md decision 2
// and ROADMAP "Phase 1.5". macOS normally registers through Vision; this small
// target lets the same fusion pipeline run OpenCV registration here so the two
// can be compared on identical frames (synth PSNR + the fluorite stack) without
// dragging the whole Linux CImaging shim (libtiff/lcms2/LibRaw/…) onto macOS.
//
// The implementation mirrors `hf_register` in Sources/CImaging/cimaging.cpp
// (the Linux backend). Kept as a separate, distinctly-named symbol so the
// experiment stays isolated from the verified Linux target; if the A/B adopts
// OpenCV on macOS too, the two collapse into one shared source at that point.
#ifndef COPENCVREGISTER_H
#define COPENCVREGISTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    hfr_ok = 0,
    hfr_fail = 1,   // no robust homography found (too few features/matches)
} hfr_status;

// Estimate the homography mapping `moving` pixels onto `fixed` pixels (both
// 8-bit gray, same top-left convention, row-major w*h). Writes a row-major 3x3
// into out_h (9 floats). Returns hfr_fail if no robust model is found.
hfr_status hfr_register(int w, int h,
                        const uint8_t* fixed, const uint8_t* moving,
                        float* out_h);

#ifdef __cplusplus
}
#endif

#endif // COPENCVREGISTER_H
