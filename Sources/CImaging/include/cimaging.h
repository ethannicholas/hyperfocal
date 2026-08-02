// C-ABI imaging shim for the non-Apple (Linux/Windows) engine build. Wraps
// libtiff / libjpeg-turbo / libpng / LibRaw (decode+encode), lcms2 (Display-P3
// color management), easyexif (EXIF), and OpenCV (homography registration) behind
// a flat `extern "C"` surface Swift can call — the same role CDNGSDK's shim
// plays for the DNG SDK. All pixel buffers are interleaved RGBA Float32 in
// Display P3 (P3 primaries, sRGB transfer), row 0 = top, values in [0,1],
// straight (non-premultiplied) alpha — matching ImageBuffer on the Swift side.
#ifndef CIMAGING_H
#define CIMAGING_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Result codes. hf_ok = success; everything else is a decode/encode failure the
// Swift layer turns into ImageFileError.
typedef enum {
    hf_ok = 0,
    hf_err_open = 1,       // could not open / read the file
    hf_err_format = 2,     // unrecognized or unsupported pixel layout
    hf_err_decode = 3,     // decoder failed mid-stream
    hf_err_encode = 4,     // encoder failed
    hf_err_unsupported = 5,// path not implemented on this platform yet
    hf_err_color = 6,      // color-management transform failed
    hf_err_register = 7,   // registration produced no usable homography
} hf_status;

// Free a buffer returned by any hf_* decode call (malloc'd by the shim).
void hf_free(void* ptr);

// ---- Decode ----------------------------------------------------------------
// Decode a standard raster (TIFF/PNG/JPEG, 8- or 16-bit) into RGBA Float32 P3.
// On success *out_rgba is a malloc'd width*height*4 float buffer (free with
// hf_free) and *out_w/*out_h are set. The embedded ICC profile (if any) is
// converted to Display P3; a file with no profile is assumed already P3.
hf_status hf_decode(const char* path, int* out_w, int* out_h, float** out_rgba);

// Decode camera RAW via LibRaw (full-quality demosaic, camera white balance),
// same RGBA Float32 P3 contract as hf_decode.
hf_status hf_decode_raw(const char* path, int* out_w, int* out_h, float** out_rgba);

// As-shot neutral chromaticity (CIE xy) from a raw file's header — no pixel
// decode. Counterpart of CIRAWFilter.neutralChromaticity on the Apple path;
// DNG export's AsShotNeutral un-bake reads it. hf_err_format when the file
// carries no usable white-balance data.
hf_status hf_raw_neutral_xy(const char* path, double* out_x, double* out_y);

// Decode any supported file to an 8-bit grayscale (luminance) plane — the
// cheap representation registration runs on. *out_gray is a malloc'd
// width*height byte buffer (free with hf_free). `is_raw` selects the RAW path.
hf_status hf_decode_gray8(const char* path, int is_raw,
                          int* out_w, int* out_h, uint8_t** out_gray);

// As hf_decode_gray8, but JPEGs may decode at a DCT-domain 1/2 or 1/4 scale:
// the largest reduction whose longest side stays >= max(min_longest,
// full_longest / scale_floor_denom). Other formats (and min_longest <= 0)
// decode at full resolution. *out_denom is the reduction actually applied
// (1, 2 or 4; scaled dims are ceil(full/denom)); *out_full_w/h are the
// file's full dimensions so the caller can map registration coordinates
// back to full-res frames.
hf_status hf_decode_gray8_scaled(const char* path, int is_raw,
                                 int min_longest, int scale_floor_denom,
                                 int* out_full_w, int* out_full_h,
                                 int* out_denom,
                                 int* out_w, int* out_h, uint8_t** out_gray);

// Pixel dimensions from the header without a full decode. is_raw selects RAW.
hf_status hf_pixel_size(const char* path, int is_raw, int* out_w, int* out_h);

// ---- Encode ----------------------------------------------------------------
// Encode an RGBA Float32 P3 buffer. `colorspace` is one of "p3", "srgb",
// "prophoto": the buffer is converted from P3 into that space and the matching
// ICC profile is embedded. TIFF/PNG are 16-bit, JPEG is 8-bit q=0.95.
//
// `datetime_original` (nullable) stamps a capture time, formatted the EXIF way
// ("YYYY:MM:DD HH:MM:SS"). It is written both as an EXIF IFD carrying
// DateTimeOriginal — what hf_exif_capture_epoch prefers, and what ImageIO
// writes on the Apple side — and as the baseline TIFF DateTime tag.
hf_status hf_encode_tiff16(const char* path, int w, int h,
                           const float* rgba, const char* colorspace,
                           const char* datetime_original);
hf_status hf_encode_png16(const char* path, int w, int h,
                          const float* rgba, const char* colorspace);
hf_status hf_encode_jpeg8(const char* path, int w, int h,
                          const float* rgba, const char* colorspace);

// ---- Animated GIF ----------------------------------------------------------
// Streaming writer for the rocking animation's GIF container: begin, add each
// frame, finish. Frames are RGBA Float32 in the P3 working space, all the same
// w*h; each is converted to sRGB and mapped to ONE global 256-colour palette,
// built at begin time from `base_rgba` (the unwarped image every frame is a
// warp of). A shared palette is both faster than per-frame quantization and
// visibly steadier — per-frame palettes make flat backgrounds crawl.
//
// The file loops forever (NETSCAPE 2.0, loop count 0), matching the ImageIO
// path on Apple. `delay_cs` is the inter-frame delay in centiseconds, GIF's
// only unit.
typedef struct hf_gif hf_gif;
hf_gif* hf_gif_begin(const char* path, int w, int h, const float* base_rgba);
hf_status hf_gif_add_frame(hf_gif* gif, const float* rgba, int delay_cs);
// Writes the trailer, closes, and frees `gif` (invalid afterwards either way).
hf_status hf_gif_finish(hf_gif* gif);
// Closes and frees without a trailer — for cancellation or an aborted write.
void hf_gif_abort(hf_gif* gif);

// ---- H.264 video -----------------------------------------------------------
// The rocking animation's other container, with the same streaming shape as the
// GIF writer above and the same frame contract (RGBA Float32 P3, w*h, converted
// to sRGB here and encoded BT.709 limited-range 4:2:0).
//
// The encoder is always one the OS supplies or a permissively-licensed
// library, because every bundleable alternative is GPL (libx264, and the
// distro FFmpeg builds configured against it) and neither an MIT source tree
// nor a paid app-store build can absorb that: Media Foundation's sink writer
// on Windows, the system OpenH264 (BSD-2-Clause) muxed by the vendored
// minimp4 on Linux (HF_HAVE_OPENH264) — both in video.cpp — matching the
// arrangement the macOS build has with AVFoundation.
//
// hf_video_available() reports whether this build carries an encoder. The
// Swift layer gates both shells' format lists and the export path on it, so
// a build without one is GIF-only up front rather than failing at write time.
//
// `fps` is the frame rate the samples are timed at; presentation times are
// derived from the frame index so they cannot drift. `w` and `h` must be even
// (4:2:0 subsampling) — hf_video_begin returns NULL rather than rounding.
int hf_video_available(void);
typedef struct hf_video hf_video;
hf_video* hf_video_begin(const char* path, int w, int h, double fps);
hf_status hf_video_add_frame(hf_video* video, const float* rgba);
// Finalizes the container, closes, and frees `video` (invalid afterwards
// either way).
hf_status hf_video_finish(hf_video* video);
// Closes and frees without finalizing, and deletes the partial file — an
// un-finalized MP4 has no moov atom and no player can open it.
void hf_video_abort(hf_video* video);

// ---- EXIF (easyexif + LibRaw fallback) -------------------------------------
// Capture time as a Unix epoch (seconds, UTC-naive) with sub-second precision
// folded in; returns hf_err_* and leaves *out_epoch untouched if absent.
hf_status hf_exif_capture_epoch(const char* path, double* out_epoch);

// Source metadata for DNG carry-over. Strings are written into caller buffers
// (truncated to the given capacities; empty string = absent). Numeric fields
// use NaN / negative sentinels for "absent" as noted. Never fails hard — a
// file with no EXIF just yields all-empty/sentinel fields and hf_ok.
typedef struct {
    double exposure_time;   // seconds, NaN if absent
    double f_number;        // NaN if absent
    double focal_length_mm; // NaN if absent
    int    iso;             // -1 if absent
} hf_exif_numbers;
hf_status hf_exif_source_meta(const char* path,
                              char* make, size_t make_cap,
                              char* model, size_t model_cap,
                              char* lens, size_t lens_cap,
                              char* datetime, size_t datetime_cap,
                              hf_exif_numbers* nums);

// ---- Registration (OpenCV) -------------------------------------------------
// Estimate the homography mapping `moving` pixels onto `fixed` pixels (both
// 8-bit gray, same top-left convention, row-major w*h). Writes a row-major 3x3
// into out_h (9 floats). Returns hf_err_register if no robust model is found.
hf_status hf_register(int w, int h,
                      const uint8_t* fixed, const uint8_t* moving,
                      float* out_h);

// Split registration: detect once per frame, match per pair. Detection (SIFT)
// dominates pair cost and every interior frame of a focus stack sits in two
// pairs, so callers registering a chain should detect each frame once and
// match handles. hf_register remains the fused convenience (and the reference
// recipe — hf_sift_match must stay byte-for-byte its match half).
typedef struct hf_sift hf_sift;   // keypoints + descriptors of one gray frame
hf_sift* hf_sift_detect(int w, int h, const uint8_t* gray);  // NULL on failure
void hf_sift_free(hf_sift* frame);
hf_status hf_sift_match(const hf_sift* fixed, const hf_sift* moving,
                        float* out_h);

#ifdef __cplusplus
}
#endif

#endif // CIMAGING_H
