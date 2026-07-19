// Implementation of the C-ABI imaging shim. See include/cimaging.h for the
// contract. Kept dependency-symmetric with the Apple ImageFile path: RGBA
// Float32, Display P3, straight alpha, row 0 = top.

#include "cimaging.h"

#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <csetjmp>

#include <tiffio.h>
#include <png.h>
#include <jpeglib.h>
#include <lcms2.h>
#include <libraw/libraw.h>

// Windows debug builds define _DEBUG, which makes OpenCV's headers wrap the
// API in a debug_build_guard namespace that only debug-built OpenCV exports.
// Swift's runtime is release-CRT (/MD) in every configuration, so we always
// link the release OpenCV; opt out of the guard.
#define CV_IGNORE_DEBUG_BUILD_GUARD
#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>   // findTransformECC

#include <exiv2/exiv2.hpp>

// MSVC's UCRT spells POSIX timegm as _mkgmtime (same contract: UTC-naive
// struct tm → epoch).
#ifdef _WIN32
#define timegm _mkgmtime
#endif

// ---------------------------------------------------------------------------
// Color management (lcms2)
// ---------------------------------------------------------------------------
namespace {

// Display P3: DCI-P3 primaries on a D65 white with the sRGB transfer curve —
// the exact space CGColorSpace.displayP3 names and the pipeline works in.
cmsHPROFILE makeDisplayP3() {
    cmsCIExyY white = {0.3127, 0.3290, 1.0};
    cmsCIExyYTRIPLE prim = {
        {0.680, 0.320, 1.0},   // red
        {0.265, 0.690, 1.0},   // green
        {0.150, 0.060, 1.0},   // blue
    };
    // sRGB parametric tone curve (IEC 61966-2.1), type 4.
    cmsFloat64Number p[5] = {2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045};
    cmsToneCurve* curve = cmsBuildParametricToneCurve(nullptr, 4, p);
    cmsToneCurve* three[3] = {curve, curve, curve};
    cmsHPROFILE prof = cmsCreateRGBProfile(&white, &prim, three);
    cmsFreeToneCurve(curve);
    return prof;
}

// Linear ProPhoto / ROMM: ROMM primaries, D50, unity gamma — the space LibRaw
// emits with output_color=4 once its output gamma is forced linear (see
// hf_decode_raw). Source side of the RAW→Display P3 transform.
cmsHPROFILE makeLinearProPhoto() {
    cmsCIExyY white = {0.3457, 0.3585, 1.0};   // D50
    cmsCIExyYTRIPLE prim = {
        {0.7347, 0.2653, 1.0},
        {0.1596, 0.8404, 1.0},
        {0.0366, 0.0001, 1.0},
    };
    cmsToneCurve* curve = cmsBuildGamma(nullptr, 1.0);
    cmsToneCurve* three[3] = {curve, curve, curve};
    cmsHPROFILE prof = cmsCreateRGBProfile(&white, &prim, three);
    cmsFreeToneCurve(curve);
    return prof;
}

// ProPhoto / ROMM RGB: ROMM primaries, D50, gamma 1.8 (values ≥ 1/512 linear).
cmsHPROFILE makeProPhoto() {
    cmsCIExyY white = {0.3457, 0.3585, 1.0};   // D50
    cmsCIExyYTRIPLE prim = {
        {0.7347, 0.2653, 1.0},
        {0.1596, 0.8404, 1.0},
        {0.0366, 0.0001, 1.0},
    };
    cmsToneCurve* curve = cmsBuildGamma(nullptr, 1.8);
    cmsToneCurve* three[3] = {curve, curve, curve};
    cmsHPROFILE prof = cmsCreateRGBProfile(&white, &prim, three);
    cmsFreeToneCurve(curve);
    return prof;
}

cmsHPROFILE profileForName(const char* name) {
    if (!name || std::strcmp(name, "p3") == 0) return makeDisplayP3();
    if (std::strcmp(name, "srgb") == 0) return cmsCreate_sRGBProfile();
    if (std::strcmp(name, "prophoto") == 0) return makeProPhoto();
    return makeDisplayP3();
}

// Convert an interleaved RGBA float buffer in-place from `src` space to `dst`
// space. Alpha rides through untouched. No-op-safe if profiles are equal.
bool convertRGBA(float* rgba, int count, cmsHPROFILE src, cmsHPROFILE dst) {
    if (!src || !dst) return false;
    cmsHTRANSFORM xf = cmsCreateTransform(
        src, TYPE_RGBA_FLT, dst, TYPE_RGBA_FLT,
        INTENT_RELATIVE_COLORIMETRIC,
        cmsFLAGS_COPY_ALPHA | cmsFLAGS_BLACKPOINTCOMPENSATION);
    if (!xf) return false;
    cmsDoTransform(xf, rgba, rgba, count);
    cmsDeleteTransform(xf);
    return true;
}

// Convert a decoded buffer that is tagged with `iccData` (or, if none, assumed
// already Display P3) into Display P3. Returns false only on a color error.
bool toDisplayP3(float* rgba, int count, const void* iccData, size_t iccLen) {
    if (!iccData || iccLen == 0) return true;  // assume already P3
    cmsHPROFILE embedded = cmsOpenProfileFromMem(iccData, (cmsUInt32Number)iccLen);
    if (!embedded) return true;  // unreadable profile → treat as P3
    cmsHPROFILE p3 = makeDisplayP3();
    bool ok = convertRGBA(rgba, count, embedded, p3);
    cmsCloseProfile(embedded);
    cmsCloseProfile(p3);
    return ok;
}

// Serialize the profile for `colorspace` to an ICC blob to embed on encode.
std::vector<unsigned char> iccBlobFor(const char* colorspace) {
    cmsHPROFILE prof = profileForName(colorspace);
    cmsUInt32Number len = 0;
    std::vector<unsigned char> blob;
    if (cmsSaveProfileToMem(prof, nullptr, &len) && len > 0) {
        blob.resize(len);
        if (!cmsSaveProfileToMem(prof, blob.data(), &len)) blob.clear();
    }
    cmsCloseProfile(prof);
    return blob;
}

// Convert a P3 buffer into the requested export space in-place.
bool fromP3(float* rgba, int count, const char* colorspace) {
    if (!colorspace || std::strcmp(colorspace, "p3") == 0) return true;
    cmsHPROFILE p3 = makeDisplayP3();
    cmsHPROFILE dst = profileForName(colorspace);
    bool ok = convertRGBA(rgba, count, p3, dst);
    cmsCloseProfile(p3);
    cmsCloseProfile(dst);
    return ok;
}

inline float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

} // namespace

extern "C" void hf_free(void* ptr) { std::free(ptr); }

// ---------------------------------------------------------------------------
// TIFF
// ---------------------------------------------------------------------------
namespace {

hf_status decodeTIFF(const char* path, int* out_w, int* out_h, float** out_rgba) {
    TIFFSetWarningHandler(nullptr);
    TIFF* tif = TIFFOpen(path, "r");
    if (!tif) return hf_err_open;
    uint32_t w = 0, h = 0;
    uint16_t bps = 8, spp = 1, fmt = SAMPLEFORMAT_UINT, planar = PLANARCONFIG_CONTIG;
    TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &w);
    TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &h);
    TIFFGetFieldDefaulted(tif, TIFFTAG_BITSPERSAMPLE, &bps);
    TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLESPERPIXEL, &spp);
    TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLEFORMAT, &fmt);
    TIFFGetFieldDefaulted(tif, TIFFTAG_PLANARCONFIG, &planar);
    if (w == 0 || h == 0 || spp < 1) { TIFFClose(tif); return hf_err_format; }

    // ICC profile (optional).
    void* icc = nullptr; uint32_t iccLen = 0;
    TIFFGetField(tif, TIFFTAG_ICCPROFILE, &iccLen, &icc);

    const size_t px = (size_t)w * h;
    float* rgba = (float*)std::malloc(px * 4 * sizeof(float));
    if (!rgba) { TIFFClose(tif); return hf_err_decode; }

    // Only contiguous 8/16-bit UINT is handled (what the pipeline ever writes);
    // fall through to libtiff's 8-bit RGBA reader otherwise.
    bool handled = (planar == PLANARCONFIG_CONTIG) &&
                   (bps == 8 || bps == 16) && (fmt == SAMPLEFORMAT_UINT);
    if (handled) {
        tmsize_t rowBytes = TIFFScanlineSize(tif);
        std::vector<uint8_t> row(rowBytes);
        const float maxv = (bps == 16) ? 65535.0f : 255.0f;
        for (uint32_t y = 0; y < h; y++) {
            if (TIFFReadScanline(tif, row.data(), y) < 0) { handled = false; break; }
            for (uint32_t x = 0; x < w; x++) {
                float r, g, b, a = 1.0f;
                auto sample = [&](int c) -> float {
                    size_t idx = (size_t)x * spp + c;
                    if (bps == 16) return ((uint16_t*)row.data())[idx] / maxv;
                    return row[idx] / maxv;
                };
                if (spp >= 3) { r = sample(0); g = sample(1); b = sample(2); }
                else { r = g = b = sample(0); }
                if (spp == 2) a = sample(1);
                if (spp >= 4) a = sample(3);
                // Un-premultiply associated alpha (pipeline writes premultiplied).
                if (a > 0.0f && a < 1.0f) { r /= a; g /= a; b /= a; }
                size_t o = ((size_t)y * w + x) * 4;
                rgba[o + 0] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = a;
            }
        }
    }
    if (!handled) {
        std::vector<uint32_t> buf(px);
        if (!TIFFReadRGBAImageOriented(tif, w, h, buf.data(), ORIENTATION_TOPLEFT, 0)) {
            std::free(rgba); TIFFClose(tif); return hf_err_decode;
        }
        for (size_t i = 0; i < px; i++) {
            uint32_t p = buf[i];
            rgba[i * 4 + 0] = TIFFGetR(p) / 255.0f;
            rgba[i * 4 + 1] = TIFFGetG(p) / 255.0f;
            rgba[i * 4 + 2] = TIFFGetB(p) / 255.0f;
            rgba[i * 4 + 3] = TIFFGetA(p) / 255.0f;
        }
    }

    if (!toDisplayP3(rgba, (int)px, icc, iccLen)) { std::free(rgba); TIFFClose(tif); return hf_err_color; }
    TIFFClose(tif);
    *out_w = (int)w; *out_h = (int)h; *out_rgba = rgba;
    return hf_ok;
}

hf_status encodeTIFF(const char* path, int w, int h,
                     const float* rgba, const char* colorspace) {
    const size_t px = (size_t)w * h;
    std::vector<float> tmp(rgba, rgba + px * 4);
    if (!fromP3(tmp.data(), (int)px, colorspace)) return hf_err_color;
    TIFF* tif = TIFFOpen(path, "w");
    if (!tif) return hf_err_open;
    TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, (uint32_t)w);
    TIFFSetField(tif, TIFFTAG_IMAGELENGTH, (uint32_t)h);
    TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, 4);
    TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, 16);
    TIFFSetField(tif, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT);
    TIFFSetField(tif, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT);
    TIFFSetField(tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
    TIFFSetField(tif, TIFFTAG_COMPRESSION, COMPRESSION_LZW);
    uint16_t extra[1] = {EXTRASAMPLE_ASSOCALPHA};
    TIFFSetField(tif, TIFFTAG_EXTRASAMPLES, 1, extra);
    auto icc = iccBlobFor(colorspace);
    if (!icc.empty()) TIFFSetField(tif, TIFFTAG_ICCPROFILE, (uint32_t)icc.size(), icc.data());

    std::vector<uint16_t> row((size_t)w * 4);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            size_t o = ((size_t)y * w + x) * 4;
            float a = clamp01(tmp[o + 3]);
            // Re-premultiply to associated alpha for storage.
            for (int c = 0; c < 3; c++)
                row[x * 4 + c] = (uint16_t)(clamp01(tmp[o + c]) * a * 65535.0f + 0.5f);
            row[x * 4 + 3] = (uint16_t)(a * 65535.0f + 0.5f);
        }
        if (TIFFWriteScanline(tif, row.data(), y) < 0) { TIFFClose(tif); return hf_err_encode; }
    }
    TIFFClose(tif);
    return hf_ok;
}

} // namespace

// ---------------------------------------------------------------------------
// PNG
// ---------------------------------------------------------------------------
namespace {

hf_status decodePNG(const char* path, int* out_w, int* out_h, float** out_rgba) {
    FILE* fp = std::fopen(path, "rb");
    if (!fp) return hf_err_open;
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png ? png_create_info_struct(png) : nullptr;
    if (!png || !info) { if (png) png_destroy_read_struct(&png, &info, nullptr); std::fclose(fp); return hf_err_decode; }
    if (setjmp(png_jmpbuf(png))) { png_destroy_read_struct(&png, &info, nullptr); std::fclose(fp); return hf_err_decode; }
    png_init_io(png, fp);
    png_read_info(png, info);
    png_uint_32 w = 0, h = 0; int bitDepth = 0, colorType = 0;
    png_get_IHDR(png, info, &w, &h, &bitDepth, &colorType, nullptr, nullptr, nullptr);
    if (colorType == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (colorType == PNG_COLOR_TYPE_GRAY && bitDepth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (colorType == PNG_COLOR_TYPE_GRAY || colorType == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (!(colorType & PNG_COLOR_MASK_ALPHA)) png_set_add_alpha(png, 0xFFFF, PNG_FILLER_AFTER);
    if (bitDepth == 16) png_set_swap(png);  // libpng is big-endian; want host
    png_read_update_info(png, info);
    int newBitDepth = png_get_bit_depth(png, info);
    const float maxv = (newBitDepth == 16) ? 65535.0f : 255.0f;

    // Embedded ICC.
    char* iccName = nullptr; int comp = 0; png_bytep iccData = nullptr; png_uint_32 iccLen = 0;
    png_get_iCCP(png, info, &iccName, &comp, &iccData, &iccLen);

    const size_t px = (size_t)w * h;
    float* rgba = (float*)std::malloc(px * 4 * sizeof(float));
    if (!rgba) { png_destroy_read_struct(&png, &info, nullptr); std::fclose(fp); return hf_err_decode; }
    std::vector<png_byte> row((size_t)w * 4 * (newBitDepth == 16 ? 2 : 1));
    for (png_uint_32 y = 0; y < h; y++) {
        png_read_row(png, row.data(), nullptr);
        for (png_uint_32 x = 0; x < w; x++) {
            float v[4];
            for (int c = 0; c < 4; c++) {
                if (newBitDepth == 16) v[c] = ((uint16_t*)row.data())[x * 4 + c] / maxv;
                else v[c] = row[x * 4 + c] / maxv;
            }
            size_t o = ((size_t)y * w + x) * 4;
            rgba[o + 0] = v[0]; rgba[o + 1] = v[1]; rgba[o + 2] = v[2]; rgba[o + 3] = v[3];
        }
    }
    bool colorOK = toDisplayP3(rgba, (int)px, iccData, iccLen);
    png_destroy_read_struct(&png, &info, nullptr);
    std::fclose(fp);
    if (!colorOK) { std::free(rgba); return hf_err_color; }
    *out_w = (int)w; *out_h = (int)h; *out_rgba = rgba;
    return hf_ok;
}

hf_status encodePNG(const char* path, int w, int h,
                    const float* rgba, const char* colorspace) {
    const size_t px = (size_t)w * h;
    std::vector<float> conv(rgba, rgba + px * 4);
    if (!fromP3(conv.data(), (int)px, colorspace)) return hf_err_color;
    FILE* fp = std::fopen(path, "wb");
    if (!fp) return hf_err_open;
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png ? png_create_info_struct(png) : nullptr;
    if (!png || !info) { if (png) png_destroy_write_struct(&png, &info); std::fclose(fp); return hf_err_encode; }
    if (setjmp(png_jmpbuf(png))) { png_destroy_write_struct(&png, &info); std::fclose(fp); return hf_err_encode; }
    png_init_io(png, fp);
    png_set_IHDR(png, info, w, h, 16, PNG_COLOR_TYPE_RGB_ALPHA,
                 PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    auto icc = iccBlobFor(colorspace);
    if (!icc.empty())
        png_set_iCCP(png, info, "ICC", 0, (png_const_bytep)icc.data(), (png_uint_32)icc.size());
    png_write_info(png, info);
    png_set_swap(png);
    std::vector<uint16_t> row((size_t)w * 4);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            size_t o = ((size_t)y * w + x) * 4;
            float a = clamp01(conv[o + 3]);
            for (int c = 0; c < 3; c++)
                row[x * 4 + c] = (uint16_t)(clamp01(conv[o + c]) * a * 65535.0f + 0.5f);
            row[x * 4 + 3] = (uint16_t)(a * 65535.0f + 0.5f);
        }
        png_write_row(png, (png_bytep)row.data());
    }
    png_write_end(png, nullptr);
    png_destroy_write_struct(&png, &info);
    std::fclose(fp);
    return hf_ok;
}

} // namespace

// ---------------------------------------------------------------------------
// JPEG
// ---------------------------------------------------------------------------
namespace {

struct jpegErrMgr { struct jpeg_error_mgr pub; jmp_buf jb; };
void jpegOnError(j_common_ptr cinfo) { longjmp(((jpegErrMgr*)cinfo->err)->jb, 1); }

hf_status decodeJPEG(const char* path, int* out_w, int* out_h, float** out_rgba) {
    FILE* fp = std::fopen(path, "rb");
    if (!fp) return hf_err_open;
    struct jpeg_decompress_struct cinfo;
    jpegErrMgr jerr;
    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpegOnError;
    float* rgba = nullptr;
    if (setjmp(jerr.jb)) { jpeg_destroy_decompress(&cinfo); if (rgba) std::free(rgba); std::fclose(fp); return hf_err_decode; }
    jpeg_create_decompress(&cinfo);
    jpeg_stdio_src(&cinfo, fp);
    jpeg_save_markers(&cinfo, JPEG_APP0 + 2, 0xFFFF);  // ICC
    jpeg_read_header(&cinfo, TRUE);
    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);
    int w = cinfo.output_width, h = cinfo.output_height;
    const size_t px = (size_t)w * h;
    rgba = (float*)std::malloc(px * 4 * sizeof(float));
    if (!rgba) longjmp(jerr.jb, 1);
    std::vector<JSAMPLE> row((size_t)w * cinfo.output_components);
    JSAMPROW rp = row.data();
    while (cinfo.output_scanline < cinfo.output_height) {
        int y = cinfo.output_scanline;
        jpeg_read_scanlines(&cinfo, &rp, 1);
        for (int x = 0; x < w; x++) {
            size_t o = ((size_t)y * w + x) * 4;
            rgba[o + 0] = row[x * 3 + 0] / 255.0f;
            rgba[o + 1] = row[x * 3 + 1] / 255.0f;
            rgba[o + 2] = row[x * 3 + 2] / 255.0f;
            rgba[o + 3] = 1.0f;
        }
    }
    unsigned char* iccData = nullptr; unsigned int iccLen = 0;
    jpeg_read_icc_profile(&cinfo, &iccData, &iccLen);
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    std::fclose(fp);
    bool colorOK = toDisplayP3(rgba, (int)px, iccData, iccLen);
    if (iccData) std::free(iccData);
    if (!colorOK) { std::free(rgba); return hf_err_color; }
    *out_w = w; *out_h = h; *out_rgba = rgba;
    return hf_ok;
}

hf_status encodeJPEG(const char* path, int w, int h,
                     const float* rgba, const char* colorspace) {
    const size_t px = (size_t)w * h;
    std::vector<float> conv(rgba, rgba + px * 4);
    if (!fromP3(conv.data(), (int)px, colorspace)) return hf_err_color;
    FILE* fp = std::fopen(path, "wb");
    if (!fp) return hf_err_open;
    struct jpeg_compress_struct cinfo;
    jpegErrMgr jerr;
    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpegOnError;
    if (setjmp(jerr.jb)) { jpeg_destroy_compress(&cinfo); std::fclose(fp); return hf_err_encode; }
    jpeg_create_compress(&cinfo);
    jpeg_stdio_dest(&cinfo, fp);
    cinfo.image_width = w; cinfo.image_height = h;
    cinfo.input_components = 3; cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, 95, TRUE);
    jpeg_start_compress(&cinfo, TRUE);
    auto icc = iccBlobFor(colorspace);
    if (!icc.empty()) jpeg_write_icc_profile(&cinfo, icc.data(), (unsigned)icc.size());
    std::vector<JSAMPLE> row((size_t)w * 3);
    JSAMPROW rp = row.data();
    while (cinfo.next_scanline < cinfo.image_height) {
        int y = cinfo.next_scanline;
        for (int x = 0; x < w; x++) {
            size_t o = ((size_t)y * w + x) * 4;
            float a = clamp01(conv[o + 3]);
            for (int c = 0; c < 3; c++)
                row[x * 3 + c] = (JSAMPLE)(clamp01(conv[o + c]) * a * 255.0f + 0.5f);
        }
        jpeg_write_scanlines(&cinfo, &rp, 1);
    }
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    std::fclose(fp);
    return hf_ok;
}

} // namespace

// ---------------------------------------------------------------------------
// RAW (LibRaw)
// ---------------------------------------------------------------------------
extern "C" hf_status hf_decode_raw(const char* path, int* out_w, int* out_h, float** out_rgba) {
    LibRaw raw;
    raw.imgdata.params.use_camera_wb = 1;
    raw.imgdata.params.output_bps = 16;
    raw.imgdata.params.output_color = 4;   // ProPhoto — wide enough to hold P3
    raw.imgdata.params.no_auto_bright = 1;
    // Linear output (LibRaw's default is the BT.709 curve, which would not
    // match any profile lcms can be handed): the transform below owns the
    // entire transfer-curve conversion into Display P3.
    raw.imgdata.params.gamm[0] = 1.0;
    raw.imgdata.params.gamm[1] = 1.0;
    // Scale strictly by the declared white level. The default (0.75) lets
    // LibRaw stretch each file by its own data maximum — a per-frame
    // brightness gain that broke DNG round-trips by ~1.14x linear (measured)
    // and would wobble exposure across a focus ramp.
    raw.imgdata.params.adjust_maximum_thr = 0;
    if (raw.open_file(path) != LIBRAW_SUCCESS) return hf_err_open;
    if (raw.unpack() != LIBRAW_SUCCESS) { raw.recycle(); return hf_err_decode; }
    if (raw.dcraw_process() != LIBRAW_SUCCESS) { raw.recycle(); return hf_err_decode; }
    int st = 0;
    libraw_processed_image_t* img = raw.dcraw_make_mem_image(&st);
    if (!img || img->type != LIBRAW_IMAGE_BITMAP || img->colors != 3 || img->bits != 16) {
        if (img) LibRaw::dcraw_clear_mem(img);
        raw.recycle();
        return hf_err_decode;
    }
    int w = img->width, h = img->height;
    const size_t px = (size_t)w * h;
    float* rgba = (float*)std::malloc(px * 4 * sizeof(float));
    if (!rgba) { LibRaw::dcraw_clear_mem(img); raw.recycle(); return hf_err_decode; }
    const uint16_t* src = (const uint16_t*)img->data;
    for (size_t i = 0; i < px; i++) {
        rgba[i * 4 + 0] = src[i * 3 + 0] / 65535.0f;
        rgba[i * 4 + 1] = src[i * 3 + 1] / 65535.0f;
        rgba[i * 4 + 2] = src[i * 3 + 2] / 65535.0f;
        rgba[i * 4 + 3] = 1.0f;
    }
    LibRaw::dcraw_clear_mem(img);
    raw.recycle();
    // The 16-bit values are linear ProPhoto (gamm forced to unity above);
    // convert primaries + white point + transfer into Display P3 in one step.
    cmsHPROFILE pp = makeLinearProPhoto();
    cmsHPROFILE p3 = makeDisplayP3();
    bool ok = convertRGBA(rgba, (int)px, pp, p3);
    cmsCloseProfile(pp); cmsCloseProfile(p3);
    if (!ok) { std::free(rgba); return hf_err_color; }
    *out_w = w; *out_h = h; *out_rgba = rgba;
    return hf_ok;
}

namespace {
// 3×3 inverse; false if singular.
bool inv3(const double m[3][3], double out[3][3]) {
    const double det =
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if (std::fabs(det) < 1e-12) return false;
    out[0][0] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det;
    out[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / det;
    out[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det;
    out[1][0] = (m[1][2] * m[2][0] - m[1][0] * m[2][2]) / det;
    out[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det;
    out[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / det;
    out[2][0] = (m[1][0] * m[2][1] - m[1][1] * m[2][0]) / det;
    out[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / det;
    out[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det;
    return true;
}

// Correlated color temperature of a chromaticity (McCamy's approximation —
// only steers the DNG dual-matrix interpolation, so accuracy demands are mild).
double cctOf(double x, double y) {
    const double n = (x - 0.3320) / (0.1858 - y);
    return ((449.0 * n + 3525.0) * n + 6823.3) * n + 5520.33;
}

// CCT of an EXIF/DNG CalibrationIlluminant code (the common ones).
double illuminantCCT(int code) {
    switch (code) {
        case 3: case 17: return 2856;   // tungsten / standard A
        case 2:          return 4200;   // fluorescent
        case 18:         return 4874;   // standard B
        case 23:         return 5003;   // D50
        case 4: case 20: return 5503;   // flash / D55
        case 19:         return 6774;   // standard C
        case 22:         return 7504;   // D75
        default:         return 6504;   // D65 and everything else
    }
}
} // namespace

// As-shot neutral chromaticity (CIE xy) from a raw header — the illuminant the
// camera's white-balance multipliers were correcting for. Header parse only,
// no pixel decode. Counterpart of CIRAWFilter.neutralChromaticity on the Apple
// path; feeds DNG export's AsShotNeutral un-bake (DNGWriter).
//
// Method is the DNG-spec white-point solve: neutral n in camera space is
// mapped to XYZ through the inverse of the XYZ→camera ColorMatrix, which
// itself depends on the illuminant — so iterate, interpolating the DNG's two
// calibration matrices by inverse CCT. Non-DNG raws carry a single D65 matrix
// (LibRaw cam_xyz, from Adobe's data); the loop then converges in one step.
// LibRaw's rgb_cam is NOT usable here: its rows are normalized so camera
// white maps to sRGB white, which destroys the colorimetry of any non-white
// vector (measured Δxy ≈ 0.06 against this solve on a Z 9 DNG).
extern "C" hf_status hf_raw_neutral_xy(const char* path, double* out_x, double* out_y) {
    LibRaw raw;
    if (raw.open_file(path) != LIBRAW_SUCCESS) return hf_err_open;
    const float* mul = raw.imgdata.color.cam_mul;   // as-shot WB multipliers
    if (!(mul[0] > 0 && mul[1] > 0 && mul[2] > 0)) { raw.recycle(); return hf_err_format; }
    // A neutral patch under the shot's illuminant records 1/mul per channel
    // (that is what the multipliers exist to flatten out).
    const double n[3] = {1.0 / mul[0], 1.0 / mul[1], 1.0 / mul[2]};

    // XYZ→camera matrices: the file's embedded DNG matrices first (dual pair
    // when both calibrations exist, either alone otherwise), cam_xyz only as
    // the non-DNG fallback. cam_xyz is NOT preferred even when filled: LibRaw
    // overwrites it from its built-in per-camera table whenever it recognizes
    // the Make/Model tags — for a DNG whose camera space is not that camera's
    // native space (our own exports declare linear Display P3, with the
    // source camera's Make/Model propagated), the embedded matrix is the
    // only correct one.
    double m1[3][3], m2[3][3];
    double cct1 = 2856, cct2 = 6504;
    bool havePair = false, haveMatrix = false;
    const auto& d0 = raw.imgdata.color.dng_color[0];
    const auto& d1 = raw.imgdata.color.dng_color[1];
    const bool have0 = d0.colormatrix[1][1] != 0;
    const bool have1 = d1.colormatrix[1][1] != 0;
    if (have0 && have1 && d0.illuminant != d1.illuminant) {
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++) {
                m1[r][c] = d0.colormatrix[r][c];
                m2[r][c] = d1.colormatrix[r][c];
            }
        cct1 = illuminantCCT(d0.illuminant);
        cct2 = illuminantCCT(d1.illuminant);
        havePair = haveMatrix = true;
    } else if (have0 || have1) {
        const auto& d = have1 ? d1 : d0;
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++) m2[r][c] = d.colormatrix[r][c];
        haveMatrix = true;
    } else if (raw.imgdata.color.cam_xyz[1][1] != 0) {
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++) m2[r][c] = raw.imgdata.color.cam_xyz[r][c];
        haveMatrix = true;
    }
    if (!haveMatrix) {
        raw.recycle();
        return hf_err_format;
    }
    raw.recycle();
    if (havePair && cct1 > cct2) { std::swap(m1, m2); std::swap(cct1, cct2); }

    double x = 0.3127, y = 0.3290;   // seed at D65
    for (int it = 0; it < 20; it++) {
        double m[3][3];
        if (havePair) {
            const double t = std::min(std::max(cctOf(x, y), cct1), cct2);
            const double w = (1 / t - 1 / cct2) / (1 / cct1 - 1 / cct2);
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    m[r][c] = w * m1[r][c] + (1 - w) * m2[r][c];
        } else {
            std::memcpy(m, m2, sizeof m);
        }
        double inv[3][3];
        if (!inv3(m, inv)) return hf_err_format;
        const double X = inv[0][0] * n[0] + inv[0][1] * n[1] + inv[0][2] * n[2];
        const double Y = inv[1][0] * n[0] + inv[1][1] * n[1] + inv[1][2] * n[2];
        const double Z = inv[2][0] * n[0] + inv[2][1] * n[1] + inv[2][2] * n[2];
        const double sum = X + Y + Z;
        if (!(sum > 0) || Y <= 0) return hf_err_format;
        const double nx = X / sum, ny = Y / sum;
        const bool settled = std::fabs(nx - x) < 1e-6 && std::fabs(ny - y) < 1e-6;
        x = nx; y = ny;
        if (settled || !havePair) break;
    }
    if (!(y > 0.0001)) return hf_err_format;
    *out_x = x;
    *out_y = y;
    return hf_ok;
}

// ---------------------------------------------------------------------------
// Dispatch by container magic
// ---------------------------------------------------------------------------
namespace {
enum Container { C_TIFF, C_PNG, C_JPEG, C_UNKNOWN };
Container sniff(const char* path) {
    FILE* fp = std::fopen(path, "rb");
    if (!fp) return C_UNKNOWN;
    unsigned char m[8] = {0};
    size_t n = std::fread(m, 1, 8, fp);
    std::fclose(fp);
    if (n >= 4 && ((m[0] == 'I' && m[1] == 'I' && m[2] == 42) ||
                   (m[0] == 'M' && m[1] == 'M' && m[3] == 42))) return C_TIFF;
    if (n >= 8 && m[0] == 0x89 && m[1] == 'P' && m[2] == 'N' && m[3] == 'G') return C_PNG;
    if (n >= 3 && m[0] == 0xFF && m[1] == 0xD8 && m[2] == 0xFF) return C_JPEG;
    return C_UNKNOWN;
}
} // namespace

extern "C" hf_status hf_decode(const char* path, int* out_w, int* out_h, float** out_rgba) {
    switch (sniff(path)) {
        case C_TIFF: return decodeTIFF(path, out_w, out_h, out_rgba);
        case C_PNG:  return decodePNG(path, out_w, out_h, out_rgba);
        case C_JPEG: return decodeJPEG(path, out_w, out_h, out_rgba);
        default:     return hf_err_format;
    }
}

extern "C" hf_status hf_decode_gray8(const char* path, int is_raw,
                                     int* out_w, int* out_h, uint8_t** out_gray) {
    int w = 0, h = 0; float* rgba = nullptr;
    hf_status s = is_raw ? hf_decode_raw(path, &w, &h, &rgba)
                         : hf_decode(path, &w, &h, &rgba);
    if (s != hf_ok) return s;
    const size_t px = (size_t)w * h;
    uint8_t* gray = (uint8_t*)std::malloc(px);
    if (!gray) { std::free(rgba); return hf_err_decode; }
    // Rec.709 luma, matching ImageBuffer.luminancePlane / the gray CGImage draw.
    for (size_t i = 0; i < px; i++) {
        float v = 0.2126f * rgba[i * 4 + 0] + 0.7152f * rgba[i * 4 + 1] + 0.0722f * rgba[i * 4 + 2];
        gray[i] = (uint8_t)(clamp01(v) * 255.0f + 0.5f);
    }
    std::free(rgba);
    *out_w = w; *out_h = h; *out_gray = gray;
    return hf_ok;
}

extern "C" hf_status hf_pixel_size(const char* path, int is_raw, int* out_w, int* out_h) {
    if (is_raw) {
        LibRaw raw;
        if (raw.open_file(path) != LIBRAW_SUCCESS) return hf_err_open;
        *out_w = raw.imgdata.sizes.iwidth;
        *out_h = raw.imgdata.sizes.iheight;
        raw.recycle();
        return hf_ok;
    }
    if (sniff(path) == C_TIFF) {
        TIFFSetWarningHandler(nullptr);
        TIFF* tif = TIFFOpen(path, "r");
        if (!tif) return hf_err_open;
        uint32_t w = 0, h = 0;
        TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &w);
        TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &h);
        TIFFClose(tif);
        if (w == 0 || h == 0) return hf_err_format;
        *out_w = (int)w; *out_h = (int)h;
        return hf_ok;
    }
    // PNG/JPEG: header sniff would be cheaper, but a decode is acceptable here
    // (pixel_size is called once per stack, not per frame).
    int w = 0, h = 0; float* rgba = nullptr;
    hf_status s = hf_decode(path, &w, &h, &rgba);
    if (s != hf_ok) return s;
    std::free(rgba);
    *out_w = w; *out_h = h;
    return hf_ok;
}

extern "C" hf_status hf_encode_tiff16(const char* path, int w, int h,
                                      const float* rgba, const char* cs) {
    return encodeTIFF(path, w, h, rgba, cs);
}
extern "C" hf_status hf_encode_png16(const char* path, int w, int h,
                                     const float* rgba, const char* cs) {
    return encodePNG(path, w, h, rgba, cs);
}
extern "C" hf_status hf_encode_jpeg8(const char* path, int w, int h,
                                     const float* rgba, const char* cs) {
    return encodeJPEG(path, w, h, rgba, cs);
}

// ---------------------------------------------------------------------------
// EXIF (exiv2)
// ---------------------------------------------------------------------------
namespace {
std::string exifString(const Exiv2::ExifData& d, const char* key) {
    auto it = d.findKey(Exiv2::ExifKey(key));
    if (it == d.end()) return std::string();
    return it->toString();
}
} // namespace

extern "C" hf_status hf_exif_capture_epoch(const char* path, double* out_epoch) {
    try {
        auto image = Exiv2::ImageFactory::open(path);
        if (!image.get()) return hf_err_open;
        image->readMetadata();
        const Exiv2::ExifData& exif = image->exifData();
        if (exif.empty()) return hf_err_format;
        std::string dt = exifString(exif, "Exif.Photo.DateTimeOriginal");
        if (dt.empty()) dt = exifString(exif, "Exif.Image.DateTime");
        if (dt.empty()) return hf_err_format;
        // "YYYY:MM:DD HH:MM:SS"
        struct tm tmv = {};
        if (sscanf(dt.c_str(), "%d:%d:%d %d:%d:%d",
                   &tmv.tm_year, &tmv.tm_mon, &tmv.tm_mday,
                   &tmv.tm_hour, &tmv.tm_min, &tmv.tm_sec) != 6) return hf_err_format;
        tmv.tm_year -= 1900; tmv.tm_mon -= 1;
        time_t t = timegm(&tmv);   // UTC-naive, matching StackSplitter.exifFormatter
        double epoch = (double)t;
        std::string sub = exifString(exif, "Exif.Photo.SubSecTimeOriginal");
        if (!sub.empty()) { double frac = std::atof(("0." + sub).c_str()); epoch += frac; }
        *out_epoch = epoch;
        return hf_ok;
    } catch (...) { return hf_err_open; }
}

extern "C" hf_status hf_exif_source_meta(const char* path,
                                         char* make, size_t make_cap,
                                         char* model, size_t model_cap,
                                         char* lens, size_t lens_cap,
                                         char* datetime, size_t datetime_cap,
                                         hf_exif_numbers* nums) {
    if (make_cap) make[0] = 0;
    if (model_cap) model[0] = 0;
    if (lens_cap) lens[0] = 0;
    if (datetime_cap) datetime[0] = 0;
    nums->exposure_time = NAN; nums->f_number = NAN;
    nums->focal_length_mm = NAN; nums->iso = -1;
    auto put = [](char* dst, size_t cap, const std::string& s) {
        if (!cap) return;
        std::strncpy(dst, s.c_str(), cap - 1);
        dst[cap - 1] = 0;
    };
    try {
        auto image = Exiv2::ImageFactory::open(path);
        if (!image.get()) return hf_ok;
        image->readMetadata();
        const Exiv2::ExifData& exif = image->exifData();
        if (exif.empty()) return hf_ok;
        put(make, make_cap, exifString(exif, "Exif.Image.Make"));
        put(model, model_cap, exifString(exif, "Exif.Image.Model"));
        std::string lensName = exifString(exif, "Exif.Photo.LensModel");
        put(lens, lens_cap, lensName);
        put(datetime, datetime_cap, exifString(exif, "Exif.Photo.DateTimeOriginal"));
        auto num = [&](const char* key, double& out) {
            auto it = exif.findKey(Exiv2::ExifKey(key));
            if (it != exif.end()) out = it->toFloat();
        };
        num("Exif.Photo.ExposureTime", nums->exposure_time);
        num("Exif.Photo.FNumber", nums->f_number);
        num("Exif.Photo.FocalLength", nums->focal_length_mm);
        auto iso = exif.findKey(Exiv2::ExifKey("Exif.Photo.ISOSpeedRatings"));
        // exiv2 0.28 renamed toLong() to toInt64(); Ubuntu 24.04 (the CI
        // container's base) still ships 0.27.
#if EXIV2_TEST_VERSION(0, 28, 0)
        if (iso != exif.end()) nums->iso = (int)iso->toInt64();
#else
        if (iso != exif.end()) nums->iso = (int)iso->toLong();
#endif
        return hf_ok;
    } catch (...) { return hf_ok; }
}

// ---------------------------------------------------------------------------
// Registration (OpenCV)
// ---------------------------------------------------------------------------
extern "C" hf_status hf_register(int w, int h,
                                 const uint8_t* fixed, const uint8_t* moving,
                                 float* out_h) {
    try {
        cv::Mat fixedM(h, w, CV_8U, (void*)fixed);
        cv::Mat movingM(h, w, CV_8U, (void*)moving);
        // SIFT: scale-space extrema are localized to sub-pixel, so the fitted
        // homography is markedly more precise than ORB's FAST corners — and
        // feature matching (unlike dense ECC) survives the appearance change
        // between focus levels that a focus stack is made of.
        cv::Ptr<cv::SIFT> sift = cv::SIFT::create();
        std::vector<cv::KeyPoint> kpF, kpM;
        cv::Mat descF, descM;
        sift->detectAndCompute(fixedM, cv::noArray(), kpF, descF);
        sift->detectAndCompute(movingM, cv::noArray(), kpM, descM);
        if (descF.empty() || descM.empty() || kpF.size() < 4 || kpM.size() < 4)
            return hf_err_register;
        cv::BFMatcher matcher(cv::NORM_L2);
        std::vector<std::vector<cv::DMatch>> knn;
        matcher.knnMatch(descM, descF, knn, 2);   // query = moving, train = fixed
        std::vector<cv::Point2f> ptsM, ptsF;
        for (auto& m : knn) {
            if (m.size() < 2) continue;
            if (m[0].distance < 0.75f * m[1].distance) {
                ptsM.push_back(kpM[m[0].queryIdx].pt);
                ptsF.push_back(kpF[m[0].trainIdx].pt);
            }
        }
        if (ptsM.size() < 4) return hf_err_register;
        cv::Mat H = cv::findHomography(ptsM, ptsF, cv::RANSAC, 3.0);
        if (H.empty()) return hf_err_register;
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                out_h[r * 3 + c] = (float)H.at<double>(r, c);
        return hf_ok;
    } catch (...) { return hf_err_register; }
}
