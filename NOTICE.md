# Third-party notices

Hyperfocal itself is MIT-licensed (see [LICENSE](LICENSE)). It ships with the
third-party components below. The set differs by platform: the **macOS** build
decodes and registers through Apple system frameworks, so it bundles almost no
third-party code; the **Windows/Linux** build uses a C imaging shim
(`Sources/CImaging`) and a Qt GUI, so it bundles the imaging and UI libraries
listed under "Windows / Linux build."

The full texts of the standard licenses referenced here (Apache-2.0, LGPL-3.0,
GPL-3.0, CDDL-1.0) are reproduced in [`licenses/`](licenses/) and are bundled
with the corresponding binary distributions.

---

## Both builds

### Adobe DNG SDK 1.7.1

`Vendor/dng_sdk/` vendors the Adobe DNG SDK (linear DNG export). Used under the
DNG SDK License Agreement (permissive; grants use/modify/distribute/sublicense
"for any purpose") — see
[`Vendor/dng_sdk/dng_sdk_license.txt`](Vendor/dng_sdk/dng_sdk_license.txt) for
the full text. Per-file notices are retained in the vendored sources.

> Copyright © 2006–2023 Adobe Systems Incorporated. All Rights Reserved.
>
> This product includes DNG technology under license by Adobe Systems
> Incorporated.

Adobe and the DNG logo are trademarks or registered trademarks of Adobe Systems
Incorporated in the United States and/or other countries. (Note: distributing
the SDK in a commercial product carries an indemnification obligation to Adobe
under §5 of the agreement.)

### zlib

Compression for the DNG SDK. License: `Zlib`.

> Copyright © 1995–2024 Jean-loup Gailly and Mark Adler.
>
> This software is provided 'as-is', without any express or implied warranty. In
> no event will the authors be held liable for any damages arising from the use
> of this software. Permission is granted to anyone to use this software for any
> purpose, including commercial applications, and to alter it and redistribute it
> freely, subject to the following restrictions: (1) The origin of this software
> must not be misrepresented … (2) Altered source versions must be plainly marked
> as such … (3) This notice may not be removed or altered from any source
> distribution.

---

## Windows / Linux build

The desktop shell and imaging shim link the following. Except where noted these
are dynamically linked (replaceable shared libraries).

### Qt 6 — LGPL-3.0

The Windows/Linux GUI (`QtShell/`) uses the Qt framework (modules: Qt Core, Gui,
Widgets, QML, Quick, ShaderTools) under the **GNU Lesser General Public License,
version 3**.

> Copyright © The Qt Company Ltd and other Qt contributors.

Qt is used as unmodified, dynamically-linked libraries. In accordance with
LGPL-3.0 §4, the corresponding source for the exact Qt version shipped is
available on request and from https://download.qt.io; the LGPL-3.0 and GPL-3.0
license texts are bundled in `licenses/`. Users may replace the Qt libraries
with modified, interface-compatible versions; a locally-deployable build (the
same one distributed outside any app store) is provided for that purpose. The
`qsb` build tool (GPL-3.0-only) is **not** redistributed — only the compiled
`.qsb` shader output and the LGPL-3.0 runtime libraries ship.

### LibRaw — used under CDDL-1.0

Camera-raw decoding. LibRaw is dual-licensed `LGPL-2.1-only OR CDDL-1.0`;
**Hyperfocal uses it under the Common Development and Distribution License,
Version 1.0 (CDDL-1.0).** No LibRaw source files are modified. Full text in
`licenses/CDDL-1.0.txt`.

> Copyright © LibRaw LLC (info@libraw.org). LibRaw uses code from dcraw,
> © Dave Coffin.

The `dng-lossy` build option additionally uses libjpeg-turbo (below); it does
not enable LibRaw's optional Adobe-DNG-SDK integration.

### OpenCV 4 — Apache-2.0

Feature detection (SIFT) and homography registration (modules core, imgproc,
features2d, calib3d, video). License: `Apache-2.0` (patent grant per §3). Full
text in `licenses/Apache-2.0.txt`.

> Copyright © the respective OpenCV contributors — including OpenCV Foundation,
> Intel Corporation, Willow Garage Inc., NVIDIA Corporation, Advanced Micro
> Devices Inc., Itseez Inc., and Xperience AI.

(SIFT is used from the main `features2d` module; the underlying patent expired in
2020. SURF is not used.)

### libtiff

TIFF read/write. License: `libtiff` (BSD-style).

> Copyright © 1988–1997 Sam Leffler.
> Copyright © 1991–1997 Silicon Graphics, Inc.
>
> Permission to use, copy, modify, distribute, and sell this software and its
> documentation for any purpose is hereby granted without fee … The above
> copyright notice and this permission notice shall appear in all copies … The
> names of Sam Leffler and Silicon Graphics may not be used in any advertising or
> publicity relating to the software without the specific, prior written
> permission of Sam Leffler and Silicon Graphics.

libtiff's LZW codec includes code developed by the University of California,
Berkeley. Materials related to distribution and use must acknowledge this:

> This product includes software developed by the University of California,
> Berkeley and its contributors.

### libpng

PNG read/write. License: `libpng-2.0` (PNG Reference Library License v2).

> Copyright © 1995–2024 The PNG Reference Library Authors, including Cosmin
> Truta, Glenn Randers-Pehrson, Andreas Dilger, Guy Eric Schalnat, and Group 42,
> Inc. The PNG Reference Library is supplied "AS IS." The copyright notice may not
> be removed or altered from any source or altered source distribution.

### libjpeg-turbo

JPEG read/write. Licenses: `IJG AND BSD-3-Clause AND Zlib`. The following
acknowledgment is required for binary distribution:

> This software is based in part on the work of the Independent JPEG Group.

> Copyright © the libjpeg-turbo Project and its contributors; portions
> © the Independent JPEG Group; portions © D. R. Commander. Redistribution and
> use in source and binary forms, with or without modification, are permitted
> provided that the copyright notice, conditions, and disclaimer are retained.

### Little CMS (lcms2)

Color management (Display-P3 transforms). License: `MIT`.

> Copyright © 1998–2024 Marti Maria Saguer.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in
> the Software without restriction … The above copyright notice and this
> permission notice shall be included in all copies or substantial portions of
> the Software.

### easyexif

EXIF metadata reading (capture time, camera/lens). Vendored at
`Sources/CImaging/easyexif/`. License: `BSD-2-Clause`.

> Copyright © 2010–2016 Mayank Lahiri (mlahiri@gmail.com). All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that redistributions retain the above
> copyright notice, this list of conditions and the following disclaimer.

### OpenCombine

`ObservableObject`/`@Published` on non-Apple platforms. License: `MIT`.

> Copyright © 2019 Sergej Jaskiewicz and OpenCombine contributors.

---

## Command-line tool only (not shipped in the app)

### swift-argument-parser

Argument parsing in `hyperfocal-cli`. License: `Apache-2.0 WITH Swift exception`
(the Runtime Library Exception waives attribution for compiled binaries).

> Copyright © Apple Inc. and the Swift project authors.

---

## Build-time tools (not distributed)

- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT) generates the Xcode
  project.
- `wgpu-native` (dual `MIT OR Apache-2.0`) is an **opt-in, non-default** compute
  backend used only for development/parity testing; it is not included in any
  shipped binary.
