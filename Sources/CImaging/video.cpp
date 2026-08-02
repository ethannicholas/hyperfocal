// H.264 writer for the rocking animation's MP4 container (hf_video_* in
// include/cimaging.h). Two implementations: Media Foundation's sink writer on
// Windows (the OS encoder), and the system OpenH264 + the vendored minimp4
// muxer on Linux (HF_HAVE_OPENH264) — see the header for the licensing that
// forces that pairing, and cimaging_priv.h for why this is a translation unit
// of its own rather than part of cimaging.cpp.

#ifdef _WIN32

// <windows.h> defines min/max as macros (breaking std::min/std::max) and pulls
// in a great deal this file never uses. Both must precede the include.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "cimaging.h"
#include "cimaging_priv.h"

#include <windows.h>
#include <codecapi.h>     // eAVEncH264VProfile_*, CODECAPI_* property GUIDs
#include <icodecapi.h>    // ICodecAPI itself (a separate SDK header)
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace {

template <class T> void release(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

inline float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

inline uint8_t clampTo(float v, int lo, int hi) {
    const int i = (int)std::lround(v);
    return (uint8_t)(i < lo ? lo : (i > hi ? hi : i));
}

// Presentation time of a frame, in Media Foundation's 100ns units. Derived
// from the frame index rather than accumulated, so a frame rate that isn't a
// clean divisor of 10^7 (29.97, say) can't drift over a long animation.
inline LONGLONG timeAt(long long frame, double fps) {
    return (LONGLONG)std::llround((double)frame * 10000000.0 / fps);
}

// sRGB float RGBA -> NV12, BT.709 limited range (Y 16–235, chroma 16–240) —
// the tagging the media type declares, and what every player assumes of H.264
// unless told otherwise.
//
// Chroma is the mean of each 2x2 block. Averaging RGB and then converting is
// exactly averaging the converted chroma (Cb/Cr are linear in R,G,B), so the
// cheaper order costs nothing. Odd dimensions would drop the last row/column's
// contribution; the caller rounds both down to even for the encoder anyway.
void toNV12(const float* rgba, int w, int h, uint8_t* nv12) {
    uint8_t* luma = nv12;
    uint8_t* chroma = nv12 + (size_t)w * h;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const float* p = rgba + ((size_t)y * w + x) * 4;
            const float v = 0.2126f * clamp01(p[0]) + 0.7152f * clamp01(p[1])
                          + 0.0722f * clamp01(p[2]);
            luma[(size_t)y * w + x] = clampTo(16.0f + 219.0f * v, 16, 235);
        }
    }
    for (int y = 0; y + 1 < h; y += 2) {
        for (int x = 0; x + 1 < w; x += 2) {
            float r = 0, g = 0, b = 0;
            for (int dy = 0; dy < 2; dy++) {
                for (int dx = 0; dx < 2; dx++) {
                    const float* p = rgba + ((size_t)(y + dy) * w + x + dx) * 4;
                    r += clamp01(p[0]); g += clamp01(p[1]); b += clamp01(p[2]);
                }
            }
            r *= 0.25f; g *= 0.25f; b *= 0.25f;
            const float v = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            uint8_t* uv = chroma + ((size_t)(y / 2) * w) + x;
            uv[0] = clampTo(128.0f + 224.0f * (b - v) / 1.8556f, 16, 240);  // Cb
            uv[1] = clampTo(128.0f + 224.0f * (r - v) / 1.5748f, 16, 240);  // Cr
        }
    }
}

// UTF-8 path -> UTF-16, the only spelling the Media Foundation APIs take.
// Empty on failure (the caller treats that as "couldn't open").
std::vector<wchar_t> widen(const char* utf8) {
    const int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (n <= 0) return {};
    std::vector<wchar_t> wide((size_t)n);
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide.data(), n) <= 0) return {};
    return wide;
}

// A frame rate as the exact rational the media type wants. Milli-fps is enough
// for every rate the app and CLI can produce, and reducing it keeps the common
// integer rates spelled 30/1 rather than 30000/1000.
void frameRate(double fps, UINT32* num, UINT32* den) {
    UINT32 n = (UINT32)std::llround(fps * 1000.0), d = 1000;
    if (n == 0) { n = 1; }
    UINT32 a = n, b = d;
    while (b) { const UINT32 t = a % b; a = b; b = t; }
    *num = n / a;
    *den = d / a;
}

} // namespace

struct hf_video {
    IMFSinkWriter* writer = nullptr;
    DWORD stream = 0;
    int w = 0, h = 0;
    double fps = 30.0;
    long long frame = 0;
    bool comInitialized = false;   // ours to balance with CoUninitialize
    bool mfStarted = false;
    std::vector<wchar_t> path;     // kept for the abort-time delete
    std::vector<float> staging;    // one frame, converted to sRGB in place
    std::vector<uint8_t> nv12;
};

namespace {

// Tear down whatever `v` managed to acquire, and delete it. `keepFile` is
// false for an abandoned write — an MP4 that never got its moov atom is not a
// file any player can open, so leaving it would only look like a broken export.
void destroy(hf_video* v, bool keepFile) {
    if (!v) return;
    release(v->writer);
    if (!keepFile && !v->path.empty()) DeleteFileW(v->path.data());
    if (v->mfStarted) MFShutdown();
    if (v->comInitialized) CoUninitialize();
    delete v;
}

} // namespace

extern "C" hf_video* hf_video_begin(const char* path, int w, int h, double fps) {
    if (!path || w <= 0 || h <= 0 || fps <= 0) return nullptr;
    // Even dimensions, refused rather than rounded: 4:2:0 subsampling needs
    // them (the caller already rounds down for exactly this reason), and the
    // NV12 plane sizes below would otherwise be half a chroma row short.
    if ((w & 1) || (h & 1)) return nullptr;

    auto v = std::make_unique<hf_video>();
    v->w = w;
    v->h = h;
    v->fps = fps;
    v->path = widen(path);
    if (v->path.empty()) return nullptr;
    v->staging.resize((size_t)w * h * 4);
    v->nv12.resize((size_t)w * h * 3 / 2);

    // RPC_E_CHANGED_MODE means the thread already belongs to an apartment of
    // the other kind — perfectly usable, but then the balancing
    // CoUninitialize is not ours to call.
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    v->comInitialized = SUCCEEDED(co);
    if (FAILED(co) && co != RPC_E_CHANGED_MODE) {
        destroy(v.release(), true);
        return nullptr;
    }
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
        destroy(v.release(), true);
        return nullptr;
    }
    v->mfStarted = true;

    IMFAttributes* attrs = nullptr;
    if (FAILED(MFCreateAttributes(&attrs, 1))) {
        destroy(v.release(), true);
        return nullptr;
    }
    // Nothing here is real-time: throttling would only make an offline export
    // slower.
    //
    // Hardware transforms are deliberately left off (the default). They would
    // buy nothing measurable — a whole 90-frame 882x590 clip encodes in well
    // under a second on the software MFT, and the warp feeding it costs more
    // than the encode — while GPU encoder MFTs are the part of this stack with
    // real per-vendor variation, including width-alignment refusals that would
    // bite exactly the odd sizes a common-coverage crop produces (882 is not a
    // multiple of 16). The software encoder ships with every Windows and takes
    // any even size. Revisit only with a measurement that needs it, on
    // hardware that can actually exercise the other path.
    attrs->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    HRESULT hr = MFCreateSinkWriterFromURL(v->path.data(), nullptr, attrs,
                                           &v->writer);
    release(attrs);
    if (FAILED(hr)) {
        destroy(v.release(), false);
        return nullptr;
    }

    UINT32 rateNum = 30, rateDen = 1;
    frameRate(fps, &rateNum, &rateDen);
    // ~0.12 bits per pixel per frame: 7.5 Mb/s at 1080p30, which is generous
    // for a rocking animation (a slow, small parallax sweep of one still —
    // there is very little for the encoder to spend bits on). Clamped so a
    // thumbnail-sized or an oversized render both stay sane.
    const double bits = (double)w * h * fps * 0.12;
    const UINT32 bitrate = (UINT32)(bits < 2000000 ? 2000000
                                                   : (bits > 24000000 ? 24000000 : bits));

    IMFMediaType* out = nullptr;
    hr = MFCreateMediaType(&out);
    if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
    if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_INTERLACE_MODE,
                                           MFVideoInterlace_Progressive);
    if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_MPEG2_PROFILE,
                                           eAVEncH264VProfile_High);
    if (SUCCEEDED(hr)) hr = MFSetAttributeSize(out, MF_MT_FRAME_SIZE,
                                               (UINT32)w, (UINT32)h);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(out, MF_MT_FRAME_RATE,
                                                rateNum, rateDen);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(out, MF_MT_PIXEL_ASPECT_RATIO,
                                                1, 1);
    // Frames arrive converted to sRGB; 709 tags are the universal "plays
    // correctly everywhere" match for that, exactly as on the AVFoundation path.
    if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE,
                                           MFNominalRange_16_235);
    if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_VIDEO_PRIMARIES,
                                           MFVideoPrimaries_BT709);
    if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_TRANSFER_FUNCTION,
                                           MFVideoTransFunc_709);
    if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_YUV_MATRIX,
                                           MFVideoTransferMatrix_BT709);
    if (SUCCEEDED(hr)) hr = v->writer->AddStream(out, &v->stream);
    release(out);
    if (FAILED(hr)) {
        destroy(v.release(), false);
        return nullptr;
    }

    IMFMediaType* in = nullptr;
    hr = MFCreateMediaType(&in);
    if (SUCCEEDED(hr)) hr = in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    if (SUCCEEDED(hr)) hr = in->SetUINT32(MF_MT_INTERLACE_MODE,
                                          MFVideoInterlace_Progressive);
    if (SUCCEEDED(hr)) hr = MFSetAttributeSize(in, MF_MT_FRAME_SIZE,
                                               (UINT32)w, (UINT32)h);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(in, MF_MT_FRAME_RATE,
                                                rateNum, rateDen);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(in, MF_MT_PIXEL_ASPECT_RATIO,
                                                1, 1);
    if (SUCCEEDED(hr)) hr = in->SetUINT32(MF_MT_DEFAULT_STRIDE, (UINT32)w);
    if (SUCCEEDED(hr)) hr = in->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE,
                                          MFNominalRange_16_235);
    if (SUCCEEDED(hr)) hr = in->SetUINT32(MF_MT_YUV_MATRIX,
                                          MFVideoTransferMatrix_BT709);
    if (SUCCEEDED(hr)) hr = v->writer->SetInputMediaType(v->stream, in, nullptr);
    release(in);

    // No B-frames. The encoder defaults to using them, which costs the file a
    // frame of reorder delay: the sink writer then stamps composition offsets
    // (a `ctts` box) and no edit list, so the first frame's presentation time
    // is 1/fps rather than 0 and a looping player has a blank frame to fill at
    // every wrap — precisely the seam this animation exists to not have.
    // Measured on the same 60-frame clip: with B-frames on, presentation ran
    // 1/30 … 2.0000 s; with them off it runs 0 … 1.9667 s. The compression
    // they would buy is irrelevant here (a slow parallax sweep of one still,
    // at a bitrate chosen to be generous).
    // Best-effort: an encoder that doesn't expose the property still encodes.
    if (SUCCEEDED(hr)) {
        ICodecAPI* codec = nullptr;
        if (SUCCEEDED(v->writer->GetServiceForStream(v->stream, GUID_NULL,
                                                     IID_PPV_ARGS(&codec)))) {
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_UI4;
            value.ulVal = 0;
            codec->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &value);
            release(codec);
        }
    }
    if (SUCCEEDED(hr)) hr = v->writer->BeginWriting();
    if (FAILED(hr)) {
        destroy(v.release(), false);
        return nullptr;
    }
    return v.release();
}

extern "C" hf_status hf_video_add_frame(hf_video* v, const float* rgba) {
    if (!v || !v->writer || !rgba) return hf_err_encode;
    std::memcpy(v->staging.data(), rgba, v->staging.size() * sizeof(float));
    if (!hfConvertFromP3(v->staging.data(), v->w * v->h, "srgb"))
        return hf_err_color;
    toNV12(v->staging.data(), v->w, v->h, v->nv12.data());

    IMFMediaBuffer* buffer = nullptr;
    if (FAILED(MFCreateMemoryBuffer((DWORD)v->nv12.size(), &buffer)))
        return hf_err_encode;
    BYTE* dst = nullptr;
    HRESULT hr = buffer->Lock(&dst, nullptr, nullptr);
    if (SUCCEEDED(hr)) {
        std::memcpy(dst, v->nv12.data(), v->nv12.size());
        buffer->Unlock();
        hr = buffer->SetCurrentLength((DWORD)v->nv12.size());
    }

    IMFSample* sample = nullptr;
    if (SUCCEEDED(hr)) hr = MFCreateSample(&sample);
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer);
    const LONGLONG start = timeAt(v->frame, v->fps);
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(start);
    if (SUCCEEDED(hr))
        hr = sample->SetSampleDuration(timeAt(v->frame + 1, v->fps) - start);
    if (SUCCEEDED(hr)) hr = v->writer->WriteSample(v->stream, sample);
    release(sample);
    release(buffer);
    if (FAILED(hr)) return hf_err_encode;
    v->frame++;
    return hf_ok;
}

extern "C" hf_status hf_video_finish(hf_video* v) {
    if (!v) return hf_err_encode;
    const bool ok = v->writer && SUCCEEDED(v->writer->Finalize());
    destroy(v, ok);
    return ok ? hf_ok : hf_err_encode;
}

extern "C" void hf_video_abort(hf_video* v) { destroy(v, false); }

extern "C" int hf_video_available(void) { return 1; }

#elif defined(HF_HAVE_OPENH264)

// Linux: OpenH264 (the system libopenh264) encodes, the vendored minimp4
// muxes. Same output contract as the Media Foundation path above: BT.709
// limited-range 4:2:0, VUI-tagged, presentation times derived from the frame
// index.

#include "cimaging.h"
#include "cimaging_priv.h"

#include <wels/codec_api.h>
#define MINIMP4_IMPLEMENTATION
#include "minimp4/minimp4.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

struct hf_video {
    std::string path;
    FILE* file = nullptr;
    MP4E_mux_t* mux = nullptr;
    mp4_h26x_writer_t writer = {};
    bool writerOpen = false;
    ISVCEncoder* enc = nullptr;
    int w = 0, h = 0;
    double fps = 30;
    long long frame = 0;
    std::vector<uint8_t> yuv;   // one frame of I420, w*h*3/2
};

namespace {

inline float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

int mp4WriteAt(int64_t offset, const void* buffer, size_t size, void* token) {
    FILE* f = (FILE*)token;
    if (fseeko(f, (off_t)offset, SEEK_SET) != 0) return 1;
    return fwrite(buffer, 1, size, f) != size;
}

// Everything below hf_video_begin allocated, in reverse; shared by the three
// teardown paths (begin-failure, finish, abort).
void teardown(hf_video* m, bool deleteFile) {
    if (m->mux) { MP4E_close(m->mux); m->mux = nullptr; }
    if (m->writerOpen) { mp4_h26x_write_close(&m->writer); m->writerOpen = false; }
    if (m->file) { fclose(m->file); m->file = nullptr; }
    if (m->enc) {
        m->enc->Uninitialize();
        WelsDestroySVCEncoder(m->enc);
        m->enc = nullptr;
    }
    if (deleteFile) std::remove(m->path.c_str());
}

// P3 float RGBA -> limited-range BT.709 I420 into m->yuv. Chroma is the
// mean of each 2x2 cell's gamma-encoded sRGB, per video convention.
bool frameToI420(hf_video* m, const float* rgba) {
    const int w = m->w, h = m->h;
    const size_t px = (size_t)w * h;
    std::vector<float> tmp(rgba, rgba + px * 4);
    if (!hfConvertFromP3(tmp.data(), (int)px, "srgb")) return false;
    uint8_t* Y = m->yuv.data();
    uint8_t* U = Y + px;
    uint8_t* V = U + px / 4;
    for (size_t i = 0; i < px; i++) {
        const float r = clamp01(tmp[i * 4]);
        const float g = clamp01(tmp[i * 4 + 1]);
        const float b = clamp01(tmp[i * 4 + 2]);
        const float luma = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        Y[i] = (uint8_t)std::lround(16.0f + 219.0f * luma);
    }
    for (int cy = 0; cy < h / 2; cy++) {
        for (int cx = 0; cx < w / 2; cx++) {
            float r = 0, g = 0, b = 0;
            for (int dy = 0; dy < 2; dy++) {
                for (int dx = 0; dx < 2; dx++) {
                    const size_t i = ((size_t)(cy * 2 + dy) * w + cx * 2 + dx) * 4;
                    r += clamp01(tmp[i]);
                    g += clamp01(tmp[i + 1]);
                    b += clamp01(tmp[i + 2]);
                }
            }
            r *= 0.25f; g *= 0.25f; b *= 0.25f;
            const float luma = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            const size_t ci = (size_t)cy * (w / 2) + cx;
            U[ci] = (uint8_t)std::lround(128.0f + 224.0f * (b - luma) / 1.8556f);
            V[ci] = (uint8_t)std::lround(128.0f + 224.0f * (r - luma) / 1.5748f);
        }
    }
    return true;
}

} // namespace

extern "C" int hf_video_available(void) { return 1; }

extern "C" hf_video* hf_video_begin(const char* path, int w, int h, double fps) {
    if (!path || w < 2 || h < 2 || (w & 1) || (h & 1) || fps <= 0) return nullptr;
    auto m = std::make_unique<hf_video>();
    m->path = path;
    m->w = w;
    m->h = h;
    m->fps = fps;
    m->yuv.resize((size_t)w * h * 3 / 2);

    if (WelsCreateSVCEncoder(&m->enc) != 0 || !m->enc) return nullptr;
    // Errors only, set before InitializeExt (which is where the noise comes
    // from): the default level prints rate-control tuning notes to the
    // console on every export (e.g. "bitrate can't be controlled ... without
    // enabling skip frame" — a trade this writer makes deliberately).
    int traceLevel = WELS_LOG_ERROR;
    m->enc->SetOption(ENCODER_OPTION_TRACE_LEVEL, &traceLevel);
    SEncParamExt p;
    m->enc->GetDefaultParams(&p);
    p.iUsageType = CAMERA_VIDEO_REAL_TIME;
    p.iPicWidth = w;
    p.iPicHeight = h;
    p.fMaxFrameRate = (float)fps;
    p.iRCMode = RC_BITRATE_MODE;
    // ~0.15 bit/pixel/frame — the neighbourhood AVAssetWriter's default
    // H.264 settings spend at these sizes, so the two platforms' files come
    // out comparable.
    p.iTargetBitrate = (int)std::min(std::max(0.15 * w * h * fps, 1e6), 4e7);
    p.iMaxBitrate = p.iTargetBitrate;
    // Offline export: never trade a dropped frame for rate — a skip would
    // also silently break the fixed per-sample duration the muxer writes.
    p.bEnableFrameSkip = false;
    p.uiIntraPeriod = 0;             // 2-6 s clips: one IDR up front
    p.iTemporalLayerNum = 1;
    p.iSpatialLayerNum = 1;
    // Single slice per frame, single-threaded: the mp4 writer emits one
    // sample per slice NAL with a full frame duration each, so a multi-slice
    // frame would stretch the timeline. Clips are short; speed is ample.
    p.iMultipleThreadIdc = 1;
    p.sSpatialLayers[0].iVideoWidth = w;
    p.sSpatialLayers[0].iVideoHeight = h;
    p.sSpatialLayers[0].fFrameRate = (float)fps;
    p.sSpatialLayers[0].iSpatialBitrate = p.iTargetBitrate;
    p.sSpatialLayers[0].iMaxSpatialBitrate = p.iMaxBitrate;
    p.sSpatialLayers[0].sSliceArgument.uiSliceMode = SM_SINGLE_SLICE;
    // Tag what the pixels actually are (sRGB primaries/matrix per BT.709,
    // limited range) — same signal the Apple path tags via
    // AVVideoColorProperties.
    p.sSpatialLayers[0].bVideoSignalTypePresent = true;
    p.sSpatialLayers[0].uiVideoFormat = VF_UNDEF;
    p.sSpatialLayers[0].bFullRange = false;
    p.sSpatialLayers[0].bColorDescriptionPresent = true;
    p.sSpatialLayers[0].uiColorPrimaries = CP_BT709;
    p.sSpatialLayers[0].uiTransferCharacteristics = TRC_BT709;
    p.sSpatialLayers[0].uiColorMatrix = CM_BT709;
    if (m->enc->InitializeExt(&p) != cmResultSuccess) {
        WelsDestroySVCEncoder(m->enc);
        m->enc = nullptr;
        return nullptr;
    }
    int fmt = videoFormatI420;
    m->enc->SetOption(ENCODER_OPTION_DATAFORMAT, &fmt);

    m->file = fopen(path, "wb");
    if (!m->file) { teardown(m.get(), false); return nullptr; }
    m->mux = MP4E_open(0 /*seekable*/, 0 /*unfragmented*/, m->file, mp4WriteAt);
    if (!m->mux) { teardown(m.get(), true); return nullptr; }
    if (mp4_h26x_write_init(&m->writer, m->mux, w, h, 0 /*h264*/)
            != MP4E_STATUS_OK) {
        teardown(m.get(), true);
        return nullptr;
    }
    m->writerOpen = true;
    return m.release();
}

extern "C" hf_status hf_video_add_frame(hf_video* m, const float* rgba) {
    if (!m || !rgba) return hf_err_encode;
    if (!frameToI420(m, rgba)) return hf_err_color;
    const size_t px = (size_t)m->w * m->h;
    SSourcePicture pic;
    std::memset(&pic, 0, sizeof pic);
    pic.iPicWidth = m->w;
    pic.iPicHeight = m->h;
    pic.iColorFormat = videoFormatI420;
    pic.iStride[0] = m->w;
    pic.iStride[1] = m->w / 2;
    pic.iStride[2] = m->w / 2;
    pic.pData[0] = m->yuv.data();
    pic.pData[1] = m->yuv.data() + px;
    pic.pData[2] = m->yuv.data() + px + px / 4;
    pic.uiTimeStamp = (long long)std::llround(m->frame * 1000.0 / m->fps);
    SFrameBSInfo info;
    std::memset(&info, 0, sizeof info);
    if (m->enc->EncodeFrame(&pic, &info) != cmResultSuccess
            || info.eFrameType == videoFrameTypeSkip) {
        return hf_err_encode;
    }
    m->frame++;
    const unsigned duration = (unsigned)std::llround(90000.0 / m->fps);
    for (int layer = 0; layer < info.iLayerNum; layer++) {
        const SLayerBSInfo& L = info.sLayerInfo[layer];
        int bytes = 0;
        for (int n = 0; n < L.iNalCount; n++) bytes += L.pNalLengthInByte[n];
        // A layer's NALs sit contiguous in pBsBuf as Annex-B; the writer
        // splits on start codes itself (SPS/PPS are cached, each slice
        // becomes one timed sample — hence single-slice frames above).
        if (mp4_h26x_write_nal(&m->writer, L.pBsBuf, bytes, duration)
                != MP4E_STATUS_OK) {
            return hf_err_encode;
        }
    }
    return hf_ok;
}

extern "C" hf_status hf_video_finish(hf_video* m) {
    if (!m) return hf_err_encode;
    std::unique_ptr<hf_video> owner(m);
    // No flush pass: OpenH264 buffers nothing (no B-frames/lookahead), so
    // every EncodeFrame already returned its bitstream synchronously.
    hf_status result = hf_ok;
    if (MP4E_close(m->mux) != MP4E_STATUS_OK) result = hf_err_encode;
    m->mux = nullptr;
    mp4_h26x_write_close(&m->writer);
    m->writerOpen = false;
    if (fclose(m->file) != 0) result = hf_err_encode;
    m->file = nullptr;
    teardown(m, result != hf_ok);
    return result;
}

extern "C" void hf_video_abort(hf_video* m) {
    if (!m) return;
    std::unique_ptr<hf_video> owner(m);
    teardown(m, true);
}

#else   // neither encoder in this build

#include "cimaging.h"

// The engine checks hf_video_available() (and NULL from hf_video_begin) and
// offers GIF only.
extern "C" int hf_video_available(void) { return 0; }

extern "C" hf_video* hf_video_begin(const char*, int, int, double) {
    return nullptr;
}

extern "C" hf_status hf_video_add_frame(hf_video*, const float*) {
    return hf_err_unsupported;
}

extern "C" hf_status hf_video_finish(hf_video*) { return hf_err_unsupported; }

extern "C" void hf_video_abort(hf_video*) {}

#endif  // _WIN32 / HF_HAVE_OPENH264
