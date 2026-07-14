// C interface to the Adobe DNG SDK for Hyperfocal.

#ifndef HYPERFOCAL_DNG_SHIM_H
#define HYPERFOCAL_DNG_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Metadata carried over from the source raw frames. String pointers may be
// NULL; numeric fields <= 0 mean absent.
typedef struct {
    const char *make;
    const char *model;
    const char *lensName;
    const char *dateTimeOriginal;   // EXIF format "YYYY:MM:DD HH:MM:SS"
    double exposureTime;            // seconds
    double fNumber;
    double focalLengthMM;
    int32_t isoSpeed;
    // As-shot neutral in the DNG's camera space (linear sRGB), max component
    // = 1. Only used when hasNeutral is nonzero; the pixel data must have had
    // the corresponding white balance divided back out.
    double asShotNeutral[3];
    int32_t hasNeutral;
    double baselineExposure;        // EV, compensates un-bake headroom scaling
} hyperfocal_dng_metadata;

// Writes a Linear DNG (16-bit linear RGB, LinearRaw photometric interpretation,
// camera space = linear sRGB) with lossless JPEG compression.
//
// rgb:        interleaved 16-bit linear RGB, width*height*3 samples
// previewRGB: optional interleaved 8-bit sRGB preview (may be NULL)
// metadata:   optional source metadata (may be NULL)
// errbuf:     receives an error message on failure (may be NULL)
//
// Returns 0 on success, nonzero on failure.
int hyperfocal_write_linear_dng(const uint16_t *rgb,
                             int32_t width,
                             int32_t height,
                             const uint8_t *previewRGB,
                             int32_t previewWidth,
                             int32_t previewHeight,
                             const char *path,
                             const char *cameraModel,
                             const hyperfocal_dng_metadata *metadata,
                             char *errbuf,
                             int32_t errbufLen);

#ifdef __cplusplus
}
#endif

#endif
