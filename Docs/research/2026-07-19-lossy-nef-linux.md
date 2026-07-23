# Lossy (High Efficiency) NEFs — findings, Windows integration, Linux punt

**Update (2026-07-23): Windows now converts automatically.** The
`RawConverter` seam sketched below is built for **native Windows**: when
LibRaw reports the format unsupported, Hyperfocal shells out to the Adobe
DNG Converter, caches a losslessly-compressed Bayer DNG
(`%LOCALAPPDATA%\Hyperfocal\DNGCache`, keyed by path+mtime+size), and
decodes that transparently. A missing converter surfaces a guided-install
dialog (button opens Adobe's download page); the CLI prints the same. See
`Sources/HyperfocalKit/RawConverter.swift`. **Linux/Wine stays deferred**
— the seam is cross-platform, so a Wine launcher plugs into
`RawConverter.locateConverter`/`runConversion` later.

**Decision (2026-07-19): punted (Linux).** Hyperfocal's Linux LibRaw path
cannot decode Nikon High Efficiency NEFs, no open-source library can, and
the only workaround (Adobe DNG Converter under Wine) added enough moving
parts that we didn't build the Linux integration then. Users with HE/HE*
files convert them to DNG externally; DNG decode through the Linux
LibRaw path is verified working (real-frame verification for ROADMAP
Phase 1 was done with DNGs for exactly this reason). Revisit if user
demand shows up or the licensing landscape changes.

## The problem

The author's own stacks (Nikon Z 9, High Efficiency compression — e.g.
the `~/Desktop/Fluorite` reference stack) don't load on Linux. Measured
failure mode: `libraw_open_file` **succeeds** (full metadata, camera
identified), then `libraw_unpack` fails with `LIBRAW_FILE_UNSUPPORTED
(-2)`. That split matters: a decoder integration would know the exact
camera and file type at the moment it fails.

## Why no open-source path exists

HE/HE* is intoPIX **TicoRAW**, patented and licensed per-SDK. LibRaw
([no ETA since 2022](https://www.libraw.org/node/2766); 0.22 only added
*reading* the NEFCompression makernote tag), dnglab, darktable/rawspeed,
and RawTherapee all lack it for licensing reasons, not technical ones.
Commercial support exists (Adobe, DxO, Capture One — all licensed
TicoRAW) but none of those ship Linux products. The intoPIX SDK is a
commercial license incompatible with an open-source project.

Affected bucket: Nikon HE/HE* (Z 8 / Z 9 / Z6III / Zf / ZR …) is the
only established format in the "LibRaw can't, converters can" class;
the same failure signature also covers cameras newer than the installed
LibRaw, so a generic detector needs no format list.

## The deferred design (if this is ever picked back up)

Helicon Focus's approach, adapted: shell out to **Adobe DNG Converter**
(freeware, HE support since 2022, headless CLI: `-c -p0 -mp -d <outdir>
<files…>`) running under Wine — a well-trodden community workflow
([RawPedia](https://rawpedia.rawtherapee.com/How_to_convert_raw_formats_to_DNG),
[install script](https://github.com/thosoo/adobe-dng-converter-installer),
[AUR `dng` package](https://aur.archlinux.org/packages/dng)). Converted
DNGs are losslessly-compressed Bayer with EXIF intact, so capture-time
stack splitting keeps working.

Sketch: (1) classify open-ok/unpack-unsupported in `hf_decode_raw` as a
distinct error carrying make/model; (2) a `RawConverter` seam that
batch-converts a failing stack into an XDG cache keyed by source
path+mtime, then decodes the DNGs — shared by CLI and Qt shell; (3)
converter discovery via standard Wine paths + `HYPERFOCAL_DNG_CONVERTER`
override, with a guided-install dialog through the existing dialog seam
when absent (Adobe's installer can't be redistributed; link, don't
bundle).

Why punted: Wine becomes a soft product dependency; the guided-install
UX is real work; and the aarch64 dev VM can't even run the x86-64
converter without an emulation layer (FEX/box64), so end-to-end
validation needs an x86-64 box. Cost outweighs benefit while external
one-time conversion works.
