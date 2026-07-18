// C ABI of HyperfocalBridge.dylib (Bridge/HyperfocalBridge.swift) — the
// command surface the Qt shell drives AppCore through.
//
// Threading contract:
//  - Every hf_* call MUST be made on the process main thread (Qt's GUI
//    thread). On macOS that thread pumps the CFRunLoop, which keeps
//    AppCore's main-queue work draining under Qt's event loop.
//  - The change callback fires on the main thread, coalesced per runloop
//    turn; model state is settled when it fires. Treat it as "something
//    changed, re-read what you display".
//
// Pixel handoff: caller-allocated RGBA8888 (QImage::Format_RGBA8888),
// row-major, width*4 stride, sized per hf_display_size.
#ifndef HYPERFOCAL_BRIDGE_H
#define HYPERFOCAL_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*hf_changed_cb)(void *ctx);
// Modal handlers. confirm returns nonzero when the user chose the
// confirm (first) button; both NULL uninstalls, and interactions then
// resolve as "cancelled" (confirms false, notices dropped).
typedef int (*hf_confirm_cb)(const char *message, const char *informative,
                             const char *confirm_title,
                             const char *cancel_title, int warning, void *ctx);
typedef void (*hf_notify_cb)(const char *message, const char *informative,
                             int warning, void *ctx);

// Create the model. Returns 1 (idempotent).
int hf_init(void);

// Register the (single) change callback; NULL unregisters.
void hf_set_changed_callback(hf_changed_cb cb, void *ctx);

// Install the shell's modal handlers (called on the main thread,
// synchronously — a modal event loop there matches the AppKit shell).
void hf_set_dialog_callbacks(hf_confirm_cb confirm, hf_notify_cb notify,
                             void *ctx);

// Load a stack: a folder of frames or a .hyperfocal project path, like a
// drop on the native app. 0 if refused (e.g. while a fuse runs).
int hf_load_stack(const char *path);

int hf_can_fuse(void);
int hf_fuse(void);        // 0 if canFuse is false
int hf_is_running(void);
double hf_stage_fraction(void);
// UTF-8 stage + ETA text into buf; returns bytes written (0 when idle).
int hf_stage_text(char *buf, int cap);

void hf_set_tone_exposure(double ev);
double hf_tone_exposure(void);

// Sliders, addressed by the accessibility-identifier vocabulary the
// native UITest command channel speaks (e.g. "fusion.slider.sharpness",
// "tone.slider.contrast") — one id namespace across both shells.
int hf_set_slider(const char *id, double value);
double hf_slider(const char *id);

// Output mode: 0 = Result, 1 = Depth (the depth map is data — it
// displays and exports untoned).
void hf_set_output_depth(int depth);
int hf_output_depth(void);

// Frame list of the selected stack, in native Stack-list order.
int hf_frame_count(void);
int hf_frame_name(int index, char *buf, int cap);   // returns bytes
int hf_frame_included(int index);
int hf_set_frame_included(int index, int included);

// Current display image: progressive preview mid-fuse, toned result
// preview otherwise. 0 sizes = nothing to show yet.
int hf_display_size(int32_t *w, int32_t *h);
// Copy it as RGBA8888 into rgba (>= w*h*4 bytes). 1 on success; 0 also
// when the image changed size since hf_display_size — re-query and retry
// on the next change callback.
int hf_display_pixels(uint8_t *rgba, size_t cap);

// Export the result through the model's export path (tone baked for
// display-referred formats, crop applied). `format`, when non-NULL, is
// the export format's UI name (e.g. "TIFF (16-bit)") applied for this
// export only — the persisted preference the native app shares is
// restored before returning. NULL uses the model's current settings.
int hf_export(const char *path, const char *format);

#ifdef __cplusplus
}
#endif

#endif // HYPERFOCAL_BRIDGE_H
