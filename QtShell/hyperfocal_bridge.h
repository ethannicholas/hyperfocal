// C ABI of HyperfocalBridge.dylib (Bridge/HyperfocalBridge.swift) — the
// command surface the Qt shell drives AppCore through.
//
// Threading contract:
//  - Every hf_* call MUST be made on the process main thread (Qt's GUI
//    thread). On macOS that thread pumps the CFRunLoop, which keeps
//    AppCore's main-queue work draining under Qt's event loop; on other
//    platforms the shell must call hf_pump_main() periodically (a Qt
//    timer — see main.cpp) or that work never runs.
//  - The change callback fires on the main thread, coalesced per runloop
//    turn; model state is settled when it fires. Treat it as "something
//    changed, re-read what you display".
//
// Pixel handoff: caller-allocated RGBA8888 (QImage::Format_RGBA8888),
// row-major, width*4 stride, fetched as tiles (hf_display_tile) of the
// current display image; hf_display_epoch says when fetched tiles went
// stale. Tone never invalidates tiles — panes apply hf_tone_lut in a
// shader.
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
// Guided-install notice: a two-button alert whose default button opens
// `url` in the browser. Used when the Adobe DNG Converter is missing.
typedef void (*hf_guide_cb)(const char *message, const char *informative,
                            const char *url, void *ctx);

// Drain the Swift main queue once, non-blocking (no-op on Apple
// platforms, where the Cocoa event loop already pumps it). Call
// periodically from the shell's event loop on Linux/Windows.
void hf_pump_main(void);

// Create the model. Returns 1 (idempotent).
int hf_init(void);

// Register the (single) change callback; NULL unregisters.
void hf_set_changed_callback(hf_changed_cb cb, void *ctx);

// Install the shell's modal handlers (called on the main thread,
// synchronously — a modal event loop there matches the AppKit shell).
void hf_set_dialog_callbacks(hf_confirm_cb confirm, hf_notify_cb notify,
                             void *ctx);

// Install the guided-download handler; NULL clears just this handler.
void hf_set_guide_callback(hf_guide_cb guide, void *ctx);

// Load a stack: a folder of frames or a .hyperfocal project path, like a
// drop on the native app. 0 if refused (e.g. while a fuse runs).
int hf_load_stack(const char *path);

int hf_can_fuse(void);
int hf_fuse(void);        // 0 if canFuse is false
int hf_is_running(void);
double hf_stage_fraction(void);
// UTF-8 stage text into buf (batch prefix included); returns bytes
// written (0 when idle). The ETA is a separate label, like native.
int hf_stage_text(char *buf, int cap);
int hf_stage_eta(char *buf, int cap);

// New Project: hf_confirm_new_project runs the discard-unsaved-work
// confirm (ask BEFORE the folder picker, like native; trivially 1 when
// nothing to lose), then hf_new_project REPLACES the stacks with the
// chosen folder — the only replacing folder load (hf_load_stack stays
// drop/add).
int hf_confirm_new_project(void);
int hf_new_project(const char *path);

// Crop editing mode — the transactional session behind the overlay.
// begin snapshots for cancel (initializing the rect to the full canvas
// when none); accept folds full-canvas/no-angle back to "no crop" and
// records the undo edit; cancel restores. While active,
// hf_display_crop reports none (panes show the whole canvas under the
// handles); read the live rect via hf_edit_crop and push candidates
// with hf_set_crop. Aspect by native label (Original/Custom/1:1/3:2/
// 5:4/4:3/16:9) reshapes area-preservingly; hf_crop_aspect_ratio is
// the active w/h lock (0 = freeform); orientation is the X-key swap.
int hf_crop_mode(void);
int hf_can_crop(void);
int hf_begin_crop(void);
int hf_accept_crop(void);
int hf_cancel_crop(void);
int hf_edit_crop(double *x, double *y, double *w, double *h,
                 double *angle);
int hf_crop_aspect(char *buf, int cap);             // returns bytes
int hf_set_crop_aspect(const char *name);
// Sidebar section collapse (names: stack/fusion/tone/retouch/export);
// persisted by the model with the other UI preferences.
int hf_section_collapsed(const char *name);
int hf_toggle_section(const char *name);
double hf_crop_aspect_ratio(void);
int hf_crop_portrait(void);
int hf_toggle_crop_orientation(void);

// Boolean settings by the native settings.* id leaves: order-by-
// capture, align, normalize-exposure, gpu, disk-cache. Persisted like
// every model setting; getter returns -1 for unknown ids.
// hf_gpu_available gates the GPU toggle (no Metal/engine = 0).
int hf_bool_setting(const char *id);
int hf_set_bool_setting(const char *id, int value);
int hf_gpu_available(void);

// Retouch: the session (pixels, strokes, undo tiles, depth co-paint,
// sources) lives entirely in AppCore; the shell forwards events in
// FULL-IMAGE pixels and draws served tiles. While hf_retouch_mode,
// the hf_display_* surface serves the session's live working image
// (or its depth view in depth mode — data, untoned); strokes bump
// hf_display_epoch and accumulate a union dirty rect the pane reads
// via hf_display_dirty (cleared on read) to evict only touched tiles.
// Undo reuses hf_undo/hf_redo, which mode-scope to strokes ("Undo
// Stroke"). Brush sliders ride the hf_set_slider namespace
// ("retouch.slider.brush-size", "retouch.slider.softness").
int hf_retouch_mode(void);
int hf_can_retouch(void);
int hf_enter_retouch(void);
int hf_exit_retouch(void);
int hf_retouch_has_edits(void);
int hf_revert_retouch(void);
int hf_display_dirty(int32_t *x, int32_t *y, int32_t *w, int32_t *h);
void hf_retouch_stroke_begin(double x, double y);
void hf_retouch_stroke_move(double x0, double y0, double x1, double y1);
void hf_retouch_stroke_end(void);
void hf_retouch_hover(double x, double y);
void hf_retouch_hover_clear(void);
int hf_retouch_can_paint(void);
int hf_retouch_cursor(double *x, double *y);
double hf_retouch_brush_radius(void);
void hf_retouch_adjust_brush(double factor);
// Source kinds: 0 frame slice, 1 PMax layer, 2 original result
// (eraser). Cycling clamps to frames; auto-pick uses the sharpness
// oracle under the hover cursor; PMax builds on demand (status text
// carries "…N%", cancel only while building).
int hf_retouch_source_kind(void);
int hf_set_retouch_source_kind(int kind);
void hf_retouch_cycle_source(int delta);
void hf_retouch_auto_pick(void);
void hf_retouch_toggle_pmax(void);
void hf_retouch_toggle_result(void);
int hf_retouch_source_name(char *buf, int cap);     // returns bytes
int hf_retouch_source_loading(void);
int hf_retouch_source_error(char *buf, int cap);    // returns bytes
int hf_retouch_source_status(char *buf, int cap);   // returns bytes
int hf_retouch_cancel_pmax(void);
// The source pane's pixel surface (mirrors hf_input_*).
int hf_retouch_source_size(int32_t *w, int32_t *h);
int hf_retouch_source_epoch(void);
int hf_retouch_source_tile(int32_t level, int32_t x, int32_t y,
                           int32_t w, int32_t h, uint8_t *rgba,
                           size_t cap);
int hf_retouch_source_nominal(int32_t *w, int32_t *h);

// Export flows. Options are persisted in the shell's own suite and
// addressed by the native UI names (ExportFormat / ExportColorSpace /
// AnimationStrength raw values: "TIFF (16-bit)" "DNG (raw)"
// "PNG (16-bit)" "JPEG"; "sRGB" "Display P3" "ProPhoto RGB"; "Subtle"
// "Medium" "Strong"). The bulk exports and the animation run async:
// they return 1 when started, and the summary (or failure) arrives
// through the notice dialog seam when done, like the native flows.
int hf_export_format(char *buf, int cap);           // returns bytes
int hf_set_export_format(const char *name);
int hf_export_color_space(char *buf, int cap);      // returns bytes
int hf_set_export_color_space(const char *name);
int hf_animation_strength(char *buf, int cap);      // returns bytes
int hf_set_animation_strength(const char *name);
// Animation format ("MP4 (H.264)" / "GIF (loops automatically)"),
// rocking path, and duration — the native animate accessory's popups.
int hf_animation_format(char *buf, int cap);        // returns bytes
int hf_set_animation_format(const char *name);
int hf_animation_path(char *buf, int cap);          // returns bytes
int hf_set_animation_path(const char *name);
int hf_animation_duration(char *buf, int cap);      // returns bytes
int hf_set_animation_duration(const char *name);
int hf_fused_stack_count(void);
int hf_can_export_aligned(void);
int hf_can_animate(void);
int hf_export_all(const char *dir);
int hf_export_aligned(const char *dir);
int hf_export_animation(const char *path);

// Project lifecycle. hf_save_project writes to `path`, or with NULL to
// the existing project file (0 when there is none — the shell then asks
// for a path, the native Save vs Save-As split). hf_project_path names
// the open project file (bytes; 0 = never saved); hf_has_unsaved_work
// drives the dirty marker and the quit gate; close-stack/close-project
// confirm destructive cases through the dialog seam.
int hf_save_project(const char *path);
int hf_project_path(char *buf, int cap);
int hf_has_unsaved_work(void);
int hf_close_stack(void);
int hf_close_project(void);

// Noise-floor drag bracket: editing=1 switches the display to a live
// depth-map preview that follows hf_set_slider moves (data
// visualization — no tone LUT; epoch bumps per re-render); 0 restores
// the normal display.
void hf_noise_floor_editing(int editing);

// Tone drag bracket: editing=1 at drag start, 0 at drag end records
// ONE undoable edit for the whole drag (mirrors the native sliders'
// onEditingChanged). Tone sets outside a bracket are silent to undo.
void hf_tone_editing(int editing);

// Undo/redo of model edits (tone, crop, frame inclusion — the native
// ⌘Z family). Titles are mode-scoped ("Undo Tone Change"); bytes out.
int hf_can_undo(void);
int hf_can_redo(void);
int hf_undo(void);
int hf_redo(void);
int hf_undo_title(char *buf, int cap);
int hf_redo_title(char *buf, int cap);

// Cancel the running fuse or batch (the progress Cancel button); 0
// when nothing is running.
int hf_cancel_fuse(void);

void hf_set_tone_exposure(double ev);
double hf_tone_exposure(void);
// Reset buttons + their visibility, mirroring the native tone.reset /
// fusion.reset (shown only when something differs from defaults).
int hf_tone_is_neutral(void);
int hf_reset_tone(void);
int hf_fusion_is_default(void);
int hf_reset_fusion(void);

// Sliders, addressed by the accessibility-identifier vocabulary the
// native UITest command channel speaks (e.g. "fusion.slider.sharpness",
// "tone.slider.contrast") — one id namespace across both shells.
int hf_set_slider(const char *id, double value);
double hf_slider(const char *id);

// Output mode: 0 = Result, 1 = Depth (the depth map is data — it
// displays and exports untoned).
void hf_set_output_depth(int depth);
int hf_output_depth(void);

// Stack list, in native Stack-tree order. Selecting a stack stashes the
// outgoing stack's state and installs the target's, like clicking its
// row in the native tree; the frame list and display then mirror it.
int hf_stack_count(void);
int hf_stack_name(int index, char *buf, int cap);      // returns bytes
int hf_stack_selected(void);                           // index, -1 = none
int hf_select_stack(int index);        // 0 while running / already selected
int hf_stack_enabled(int index);       // the batch-fuse checkbox
int hf_set_stack_enabled(int index, int enabled);
// 0 unfused, 1 fusing, 2 fused, 3 failed (hf_stack_failure = message).
int hf_stack_status(int index);
int hf_stack_failure(int index, char *buf, int cap);   // returns bytes
int hf_stack_frame_count(int index);
// Tree disclosure + any stack's nested frame rows (name/included/
// issue by stack+frame index, through the same model helpers native
// uses; inclusion toggles are URL-global and undo-recorded).
int hf_stack_expanded(int index);
int hf_set_stack_expanded(int index, int expanded);
int hf_stack_frame_name(int stack, int frame, char *buf, int cap);
int hf_stack_frame_included(int stack, int frame);
int hf_set_stack_frame_included(int stack, int frame, int included);
int hf_stack_frame_issue(int stack, int frame, char *buf, int cap);

// Batch fuse ("Fuse N Stacks"): N = hf_pending_stack_count (enabled +
// needing a (re)fuse). hf_is_running holds for the whole batch and
// hf_stage_text carries the "Stack i of N · " prefix; bad stacks are
// reported through the notice dialog seam at the end, like the native
// app. 0 when refused (running) or nothing is pending.
int hf_pending_stack_count(void);
int hf_fuse_enabled_stacks(void);

// Frame list of the selected stack, in native Stack-list order.
int hf_frame_count(void);
int hf_frame_name(int index, char *buf, int cap);   // returns bytes
int hf_frame_included(int index);
int hf_set_frame_included(int index, int included);
// Badges: a frame's fuse-time issue summary (misfire/misalignment) and
// a stack's load-time frame-order warning. Return bytes; 0 = none.
int hf_frame_issue(int index, char *buf, int cap);
int hf_stack_order_warning(int index, char *buf, int cap);

// Frame selection + the input pane. Selecting a frame (like clicking
// its row) points the input pane at it; decoding is async — re-read on
// change callbacks, hf_input_epoch says when pixels moved. The input
// image is the selected frame's preview (decoded raw, or warped into
// the fused canvas once alignment transforms exist — the title carries
// " (aligned)"), or the cycling processing source mid-fuse. The pane
// tones it with the same LUT as the output, matching the native app.
int hf_select_frame(int index);
// Any stack's frame, like clicking its nested tree row — a frame in
// another stack switches stack selection with it (no-op while running).
int hf_select_stack_frame(int stack, int frame);
int hf_selected_frame(void);                        // index, -1 = none
int hf_input_size(int32_t *w, int32_t *h);
int hf_input_epoch(void);
int hf_input_tile(int32_t level, int32_t x, int32_t y,
                  int32_t w, int32_t h, uint8_t *rgba, size_t cap);
int hf_input_title(char *buf, int cap);             // returns bytes
// 1 while the selected frame's decode is in flight: hf_input_tile still
// serves the previous image even though hf_input_title already names the
// new frame — wait for 0 before trusting input pixels.
int hf_input_loading(void);

// Crop, in result-canvas pixels + degrees. hf_set_crop mirrors the
// UITest set-crop command (w/h <= 0 clears). hf_display_crop /
// hf_input_crop report the crop each pane should present (1 = active):
// the pane restricts its viewport to the rect — the image rotated by
// -angle about the rect's center, clipped to the rect, the region
// hf_export writes. Crop changes never move the pixel epochs; the
// input pane crops only when its preview is aligned into the canvas.
int hf_set_crop(double x, double y, double w, double h, double angle);
int hf_display_crop(double *x, double *y, double *w, double *h,
                    double *angle);
int hf_input_crop(double *x, double *y, double *w, double *h,
                  double *angle);

// Current display image: progressive preview mid-fuse, the full-res
// result preview otherwise — always UNTONED; the pane applies
// hf_tone_lut in its LUT shader unless hf_display_is_data says the
// image is a data visualization (aligner gradients, depth). 0 sizes =
// nothing to show.
int hf_display_size(int32_t *w, int32_t *h);
// Pixel epoch: bumps only when the display image's pixels change
// (progressive updates, fuse completion, Result/Depth toggle) — never
// for tone edits. Fetched tiles stay valid while it holds.
int hf_display_epoch(void);
// Copy a tile as RGBA8888 into rgba (>= w*h*4 bytes). `level` is a
// power-of-two downsample exponent (0 = native); the level image
// measures ceil(size / 2^level) and x/y/w/h must lie inside it.
// Nearest sampling. 1 on success; 0 also when the image changed since
// hf_display_size — re-query and retry on the next change callback.
int hf_display_tile(int32_t level, int32_t x, int32_t y,
                    int32_t w, int32_t h, uint8_t *rgba, size_t cap);
int hf_display_is_data(void);
// Nominal canvas sizes — the viewport coordinate space. Differ from
// the pixel sizes only mid-fuse (progressives render smaller than the
// final canvas); mapping through nominal keeps pan/zoom stable.
int hf_display_nominal(int32_t *w, int32_t *h);
int hf_input_nominal(int32_t *w, int32_t *h);
// The tone curve as `size` 16-bit grayscale entries (per-channel-
// separable — one shared ramp is the entire color cube).
int hf_tone_lut(uint16_t *out, int size);

// Export the result through the model's export path (tone baked for
// display-referred formats, crop applied). `format`, when non-NULL, is
// the export format's UI name (e.g. "TIFF (16-bit)") applied for this
// export only — the persisted preference (the shell's own settings
// suite; see HYPERFOCAL_SETTINGS_SUITE in main.cpp) is restored before
// returning. NULL uses the model's current settings.
int hf_export(const char *path, const char *format);

#ifdef __cplusplus
}
#endif

#endif // HYPERFOCAL_BRIDGE_H
