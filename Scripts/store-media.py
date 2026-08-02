#!/usr/bin/env python3
"""App-store media capture driver (macOS side).

Stages the real app and captures store-ready marketing media, repeatably —
the point is regenerating every screenshot/video after any UI change, in
every language, without a human at the mouse:

  * a fusion-workflow video sized/encoded for Mac App Store app previews
    (1920x1080 H.264 30fps, silent stereo AAC — App Store Connect rejects
    previews with no audio track — sped to fit the 15-30 s window), and
  * retouch-mode screenshots at an exact store size (default 2880x1800,
    a 1440x900-point window on a 2x display) with the real crosshair
    cursor captured (`screencapture -C`) over a caller-chosen image point.

Drives the app through the UITestSupport command channel (see
App/Sources/UITestSupport.swift): launch-env seeding + distributed
notifications in, result files out of the sandbox container. The stack
folder is copied into the container first — the sandboxed app can read
nothing else without a panel grant.

Example (stack folder and coordinates are the caller's; image coordinates
are in fused-output pixels):

  Scripts/store-media.py --frames <stack-dir> --out /tmp/media \\
      --exposure 0.5 --shadows 20 --video-zoom 0.18 \\
      --shot-center 2522,945 --cursor 2638,1040

Captures every catalog language by default, one app session each — the app
localizes via AppleLanguages, the shared layer via HYPERFOCAL_LANG; the
driver sets both. `--lang <tag>` (or a comma list) restricts the run, which
is only ever wanted for testing.

Takes over the screen (window staging, cursor moves) — get a yes from the
user before running, same etiquette as Scripts/ui-test.sh.
"""

import argparse
import glob
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONTAINER = Path.home() / "Library/Containers/com.ethannicholas.hyperfocal/Data"
STAGE = CONTAINER / "tmp/hyperfocal-store"
BUNDLE_NAME = "Hyperfocal"

JXA_POST = """
function run(argv) {
    ObjC.import("Foundation");
    $.NSDistributedNotificationCenter.defaultCenter
        .postNotificationNameObjectUserInfoDeliverImmediately(
            "org.hyperfocal.uitest.command", argv[0], undefined, true);
}
"""

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".dng", ".heic"}

# The localization catalog (CLAUDE.md): store listings exist for every one
# of these, so a capture run defaults to all of them — a single language is
# only ever wanted for testing.
LANGS = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "ru",
         "zh-Hans"]


def log(msg):
    print(f"== {msg}", flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def parse_pair(s):
    x, y = s.split(",")
    return float(x), float(y)


def parse_size(s):
    w, h = s.lower().split("x")
    return float(w), float(h)


class App:
    """One launched capture session: command posting + geometry polling."""

    def __init__(self, binary, env, args):
        self.counter = 0
        self.results = STAGE / "results"
        shutil.rmtree(self.results, ignore_errors=True)
        self.results.mkdir(parents=True)
        logfile = open(STAGE / "app.log", "w")
        self.proc = subprocess.Popen([str(binary)] + args, env=env,
                                     stdout=logfile, stderr=logfile)

    def post(self, action, timeout=15, soft=False, **kw):
        """Send one command; return its parsed result payload.

        soft=True returns None on a timeout instead of exiting — the poll
        loops need that, because a command posted before the app finishes
        booting (or while it's saturating the machine mid-fuse) is simply a
        lost notification, not a failure.
        """
        self.counter += 1
        result = self.results / f"r{self.counter}.json"
        payload = {"action": action, "result": str(result)}
        payload.update({k.replace("_", "-"): str(v) for k, v in kw.items()})
        run(["osascript", "-l", "JavaScript", "-e", JXA_POST,
             json.dumps(payload)], capture_output=True)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                sys.exit(f"error: app exited (see {STAGE / 'app.log'})")
            if result.exists():
                time.sleep(0.05)  # let the write finish
                return json.loads(result.read_text())
            time.sleep(0.2)
        if soft:
            return None
        sys.exit(f"error: command {action} timed out after {timeout}s")

    def require(self, action, **kw):
        r = self.post(action, **kw)
        if r.get("ok") != "1":
            sys.exit(f"error: {action} failed: {r.get('detail', r)}")
        return r

    def wait_until(self, what, pred, timeout, interval=1.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            geo = self.post("get-geometry", timeout=10, soft=True)
            if geo is not None and pred(geo):
                return geo
            time.sleep(interval)
        sys.exit(f"error: timed out after {timeout}s waiting for {what}")

    def activate(self):
        # Retried without check: right after launch the process hasn't
        # registered with System Events yet.
        for _ in range(10):
            ok = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to set frontmost of '
                 f'(first process whose unix id is {self.proc.pid}) to true'],
                capture_output=True).returncode == 0
            if ok:
                break
            time.sleep(1)
        else:
            log("WARNING: could not foreground the app")
        time.sleep(1)

    def quit(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def focus_terminal():
    name = {"Apple_Terminal": "Terminal", "iTerm.app": "iTerm2"}.get(
        os.environ.get("TERM_PROGRAM", ""))
    if name:
        subprocess.run(["osascript", "-e",
                        f'tell application "{name}" to activate'],
                       capture_output=True)


def find_app():
    products = sorted(
        glob.glob(str(Path.home() / "Library/Developer/Xcode/DerivedData"
                      / "Hyperfocal-*/Build/Products/Debug"
                      / f"{BUNDLE_NAME}.app")),
        key=os.path.getmtime)
    if not products:
        sys.exit("error: no built app in DerivedData (run without --skip-build)")
    return Path(products[-1]) / "Contents/MacOS" / BUNDLE_NAME


def build_app():
    log("building app")
    run(["xcodegen", "generate"], cwd=REPO / "App", capture_output=True)
    run(["xcodebuild", "-project", "Hyperfocal.xcodeproj", "-scheme",
         "Hyperfocal", "-configuration", "Debug", "-destination",
         "platform=macOS", "build"], cwd=REPO / "App", capture_output=True)


def build_mouse_helper():
    helper = STAGE / "mouse-move"
    src = REPO / "Scripts/store-media-mouse.swift"
    if not helper.exists() or helper.stat().st_mtime < src.stat().st_mtime:
        run(["swiftc", "-O", "-o", str(helper), str(src)], capture_output=True)
    return helper


def stage_frames(frames_dir):
    dest = STAGE / "frames"
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    n = 0
    for f in sorted(Path(frames_dir).iterdir()):
        if f.suffix.lower() in IMAGE_EXTS:
            shutil.copy2(f, dest / f.name)
            n += 1
    if not n:
        sys.exit(f"error: no frames in {frames_dir}")
    log(f"staged {n} frames into the app container")
    return dest


def capture_rect(geo):
    w = geo["window"]
    return (f"{int(w['x'])},{int(w['y'])},{int(w['w'])},{int(w['h'])}", w)


def image_to_screen(geo, ix, iy, pane_class=None):
    """The pane views' own mapping (UITestSupport get-geometry doc)."""
    panes = geo["panes"]
    if pane_class:
        panes = [p for p in panes if p["class"] == pane_class] or panes
    pane = panes[0]["frame"]
    scale = geo["viewportScale"]
    img = geo["image"]
    sx = pane["x"] + pane["w"] / 2 + (ix - img["w"] / 2 - geo["offsetW"]) * scale
    sy = pane["y"] + pane["h"] / 2 + (iy - img["h"] / 2 - geo["offsetH"]) * scale
    return sx, sy


def encode_video(raw, out, target_seconds):
    probe = json.loads(subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "json", str(raw)]))
    duration = float(probe["format"]["duration"])
    speed = max(duration / target_seconds, 1.0)
    log(f"raw recording {duration:.1f}s -> {speed:.2f}x to fit {target_seconds}s")
    if duration < 15:
        log("WARNING: raw recording under 15s — App Store previews need 15-30s")
    vf = f"setpts=PTS/{speed:.6f},fps=30,scale=1920:1080:flags=lanczos,format=yuv420p"
    run(["ffmpeg", "-y", "-v", "error", "-i", str(raw),
         "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
         "-map", "0:v", "-map", "1:a", "-vf", vf,
         "-c:v", "libx264", "-profile:v", "high", "-crf", "18",
         "-c:a", "aac", "-b:a", "96k", "-shortest",
         "-movflags", "+faststart", str(out)])


def validate_video(path):
    streams = json.loads(subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=codec_type,codec_name,width,height,channels:format=duration",
         "-of", "json", str(path)]))
    video = next(s for s in streams["streams"] if s["codec_type"] == "video")
    audio = [s for s in streams["streams"] if s["codec_type"] == "audio"]
    duration = float(streams["format"]["duration"])
    problems = []
    if (video["width"], video["height"]) != (1920, 1080):
        problems.append(f"size {video['width']}x{video['height']} != 1920x1080")
    if video["codec_name"] != "h264":
        problems.append(f"codec {video['codec_name']} != h264")
    if not audio:
        problems.append("no audio track (App Store Connect rejects silent-less previews)")
    elif audio[0].get("channels") != 2:
        problems.append("audio not stereo")
    if not 15 <= duration <= 30:
        problems.append(f"duration {duration:.1f}s outside 15-30s")
    if problems:
        sys.exit("error: video validation failed: " + "; ".join(problems))
    log(f"video OK: 1920x1080 h264 + stereo audio, {duration:.1f}s")


def validate_screenshot(path, expect_px):
    out = subprocess.check_output(["sips", "-g", "pixelWidth", "-g",
                                   "pixelHeight", str(path)]).decode()
    dims = [int(l.split(":")[1]) for l in out.splitlines() if ":" in l]
    if tuple(dims) != expect_px:
        sys.exit(f"error: screenshot is {dims[0]}x{dims[1]}, wanted "
                 f"{expect_px[0]}x{expect_px[1]}")
    log(f"screenshot OK: {dims[0]}x{dims[1]}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--frames", required=True, help="stack folder to capture")
    p.add_argument("--out", required=True, help="output directory")
    p.add_argument("--lang", default="all",
                   help='languages to capture: "all" (default) or a comma '
                   "list of catalog tags (en,de,pt-BR,...) — a single tag "
                   "is for testing")
    p.add_argument("--skip-build", action="store_true")
    p.add_argument("--video", action="store_true", help="capture only the video")
    p.add_argument("--screenshot", action="store_true",
                   help="capture only the screenshot")
    p.add_argument("--exposure", type=float, default=0.0, help="EV")
    p.add_argument("--shadows", type=float, default=0.0)
    p.add_argument("--video-zoom", type=float, default=0.16,
                   help="viewport scale during the fusion video")
    p.add_argument("--video-window", default="1440x810",
                   help="window points; x2 must downscale to 16:9 1920x1080")
    p.add_argument("--video-duration", type=float, default=25,
                   help="target seconds after speed-up (App Store: 15-30)")
    p.add_argument("--shot-window", default="1280x800",
                   help="window points; x2 is the store pixel size (16:10). "
                   "1280x800 -> 2560x1600, an accepted Mac App Store size "
                   "that still fits under the Dock (macOS clamps windows to "
                   "the visible frame, so 1440x900 is unreachable when a "
                   "Dock is showing)")
    p.add_argument("--shot-zoom", type=float, default=1.0)
    p.add_argument("--shot-center", type=parse_pair, default=None,
                   help="image point to center the retouch view on, x,y")
    p.add_argument("--cursor", type=parse_pair, default=None,
                   help="image point to park the cursor on, x,y")
    p.add_argument("--collapse", default="stack,fusion",
                   help="sidebar sections collapsed for the screenshot; the "
                   "video always shows the full sidebar (comma list of "
                   "stack,fusion,tone,retouch,export; empty = all expanded)")
    p.add_argument("--keep-raw", action="store_true")
    args = p.parse_args()
    do_video = args.video or not args.screenshot
    do_shot = args.screenshot or not args.video

    if not CONTAINER.is_dir():
        sys.exit("error: app container missing — launch Hyperfocal once first")
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    STAGE.mkdir(parents=True, exist_ok=True)

    if not args.skip_build:
        build_app()
    binary = find_app()
    mouse = build_mouse_helper()
    frames = stage_frames(args.frames)

    langs = LANGS if args.lang == "all" else args.lang.split(",")
    unknown = [l for l in langs if l not in LANGS]
    if unknown:
        sys.exit(f"error: unknown language tag(s) {','.join(unknown)} — "
                 f"catalog: {','.join(LANGS)}")
    try:
        for i, lang in enumerate(langs, 1):
            log(f"language {lang} ({i}/{len(langs)})")
            capture_language(lang, args, do_video, do_shot,
                             binary, mouse, frames, out_dir)
    finally:
        focus_terminal()
    log(f"done -> {out_dir}")


def capture_language(lang, args, do_video, do_shot, binary, mouse, frames,
                     out_dir):
    """One full app session: launch localized, fuse, capture, quit."""
    shot_w, shot_h = parse_size(args.shot_window)

    env = dict(os.environ)
    env.update(HYPERFOCAL_UITEST="1", HYPERFOCAL_AUTOCONFIRM="1",
               HYPERFOCAL_LOAD_STACK=str(frames),
               HYPERFOCAL_WINDOW=(args.video_window if do_video
                                  else args.shot_window))
    launch_args = []
    if lang != "en":
        env["HYPERFOCAL_LANG"] = lang
        launch_args += ["-AppleLanguages", f"({lang})"]

    app = App(binary, env, launch_args)
    try:
        # Foreground immediately — the approval that launched this script
        # put the terminal on top of where the app window appears.
        time.sleep(3)
        app.activate()
        # Neutral-tone panes are plain SwiftUI Images — ToneFilteredPaneView
        # (what get-geometry reports) only exists once tone is non-neutral or
        # retouch is active, so ingest readiness is phase alone.
        app.wait_until("stack ingest", lambda g: g.get("phase") == "loaded",
                       timeout=120)
        app.activate()

        if args.exposure:
            app.require("set-slider", id="tone.slider.exposure",
                        value=args.exposure)
        if args.shadows:
            app.require("set-slider", id="tone.slider.shadows",
                        value=args.shadows)

        if do_video:
            app.require("set-zoom", scale=args.video_zoom)
            time.sleep(1)
            geo = app.post("get-geometry")
            rect, w = capture_rect(geo)
            raw = STAGE / "raw-video.mov"
            raw.unlink(missing_ok=True)
            # Park the pointer outside the capture rect — the recording
            # includes it. CGEvent clamps to the screen edge, which is still
            # outside the window.
            run([str(mouse), f"{w['x'] + w['w'] + 40}", f"{w['y'] + w['h'] / 2}"])
            log(f"recording fusion at {rect}")
            rec = subprocess.Popen(["screencapture", "-v", "-R", rect, str(raw)])
            time.sleep(2)
            app.require("fuse")
            app.wait_until("fuse", lambda g: g.get("phase") == "done",
                           timeout=1800, interval=2)
            time.sleep(3)  # let the finished result render
            rec.send_signal(signal.SIGINT)
            rec.wait(timeout=60)
            video_out = out_dir / f"mac-{lang}-fusion-1920x1080.mp4"
            encode_video(raw, video_out, args.video_duration)
            validate_video(video_out)
            if not args.keep_raw:
                raw.unlink()

        if do_shot:
            if not do_video:  # otherwise the fuse above already ran
                app.require("fuse")
                app.wait_until("fuse", lambda g: g.get("phase") == "done",
                               timeout=1800, interval=2)
            # Screenshot only: the retouch shot frames Tone + Retouching.
            # The video keeps every section expanded — the stack list is the
            # visual feedback during the fuse, and the Fusion panel is where
            # the user just clicked.
            if args.collapse:
                app.require("set-sections", collapsed=args.collapse)
            app.require("set-window", w=shot_w, h=shot_h)
            time.sleep(1)
            got = app.post("get-geometry")["window"]
            if (got["w"], got["h"]) != (shot_w, shot_h):
                sys.exit(f"error: window is {got['w']}x{got['h']}, asked for "
                         f"{shot_w}x{shot_h} — macOS clamps windows to the "
                         "visible frame (Dock/menu bar); pick a smaller "
                         "--shot-window")
            # Retouch needs the result + depth settled; the command reports
            # not-ready instead of blocking, so poll briefly.
            for _ in range(30):
                if app.post("enter-retouch").get("ok") == "1":
                    break
                time.sleep(1)
            else:
                sys.exit("error: enter-retouch never became ready")
            app.require("set-retouch", source="pmax")
            app.wait_until("PMax retouch source",
                           lambda g: g.get("canPaint")
                           and not g.get("sourceLoading"),
                           timeout=1800, interval=2)
            zoom = {"scale": args.shot_zoom}
            if args.shot_center:
                zoom.update(cx=args.shot_center[0], cy=args.shot_center[1])
            app.require("set-zoom", **zoom)
            time.sleep(1)
            app.activate()
            geo = app.post("get-geometry")
            rect, w = capture_rect(geo)
            if args.cursor:
                # Over the canvas (right) pane: the crosshair cursor-rect and
                # hover tracking live there, and hovering it draws the brush
                # circle in both panes.
                sx, sy = image_to_screen(geo, *args.cursor,
                                         pane_class="RetouchCanvasNSView")
                log(f"cursor -> screen ({sx:.0f}, {sy:.0f})")
                run([str(mouse), f"{sx}", f"{sy}"])
                time.sleep(1)  # tracking area fires; brush circle draws
            scale = int(geo.get("backingScale", 2))
            expect = (int(shot_w * scale), int(shot_h * scale))
            shot_out = (out_dir / f"mac-{lang}-retouch-"
                        f"{expect[0]}x{expect[1]}.png")
            run(["screencapture", "-x", "-C", "-R", rect, str(shot_out)])
            validate_screenshot(shot_out, expect)
    finally:
        app.quit()


if __name__ == "__main__":
    main()
