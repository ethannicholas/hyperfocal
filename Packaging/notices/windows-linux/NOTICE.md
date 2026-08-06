# Third-party notices

Hyperfocal includes third-party software under separate licenses.

The full texts of the standard licenses referenced here are available at
https://github.com/ethannicholas/hyperfocal/tree/main/licenses.

### Adobe DNG SDK 1.7.1

`Vendor/dng_sdk/` vendors the Adobe DNG SDK (linear DNG export). Used under the
DNG SDK License Agreement (permissive; grants use/modify/distribute/sublicense
"for any purpose") — see
[`Vendor/dng_sdk/dng_sdk_license.txt`](https://github.com/ethannicholas/hyperfocal/tree/main/Vendor/dng_sdk/dng_sdk_license.txt) for
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

### Qt 6 — LGPL-3.0

The Windows/Linux GUI (`QtShell/`) uses the Qt framework under the **GNU Lesser
General Public License, version 3**. The shell links Qt Core, Gui, Widgets, Qml,
Quick and ShaderTools directly; `windeployqt` additionally stages the modules
those pull in at runtime — Network, OpenGL, Svg, QuickControls2 (with its Basic,
Fusion, Imagine, Material, Universal and FluentWinUI3 styles), QuickDialogs2,
QuickEffects, QuickLayouts, QuickShapes, QuickTemplates2, QmlMeta, QmlModels,
QmlWorkerScript and LabsFolderListModel — all under the same license.

> Copyright © The Qt Company Ltd and other Qt contributors.

Qt is used as unmodified, dynamically-linked libraries — every Qt library ships
as a separate DLL/shared object, never statically linked into the executable.
The corresponding source for the exact Qt version shipped is available from
https://download.qt.io and, for three years from the date of this distribution,
on request from the maintainer at no more than the cost of distribution; the
LGPL-3.0 and GPL-3.0 license texts are bundled in `licenses/`.

The relinking right under LGPL-3.0 §4(d)(0) is satisfied by source: the whole of
Hyperfocal is MIT-licensed and public at
https://github.com/ethannicholas/hyperfocal, with a reproducible build, so
anyone may rebuild the application against a modified, interface-compatible Qt
and run the result. The `qsb` build tool (GPL-3.0-only) is **not** redistributed
— only the compiled `.qsb` shader output and the LGPL-3.0 runtime libraries
ship.

### DirectX shader compilers — Microsoft Windows SDK Distributable Code

The Windows package ships `dxcompiler.dll`, `dxil.dll` and `d3dcompiler_47.dll`,
copied by `windeployqt` from `Windows Kits\10\Redist\D3D\<arch>\`. Qt loads them
at runtime for its Direct3D RHI backends — the first two for Direct3D 12, and
`d3dcompiler_47.dll` for HLSL compilation on the Direct3D 11 path. They are
**Microsoft binaries, not covered by Hyperfocal's MIT license**, redistributed as
"Distributable Code" under the Microsoft Software License Terms for the Windows
Software Development Kit — which list the `Redist\D3D\x64\` and `Redist\D3D\x86\`
copies of all three as redistributable with Classic Windows applications.

> Copyright © Microsoft Corporation. All rights reserved.

`dxcompiler.dll` is built from Microsoft's DirectX Shader Compiler, which
incorporates LLVM and Clang under the University of Illinois/NCSA Open Source
License, the LLVM System Interface Library, and OpenBSD regex (Henry Spencer).
Microsoft's notice for those components is reproduced verbatim — it is marked
"Do Not Translate or Localize" — in
[`licenses/DirectXShaderCompiler-ThirdPartyNotices.txt`](https://github.com/ethannicholas/hyperfocal/tree/main/licenses/DirectXShaderCompiler-ThirdPartyNotices.txt),
and is bundled with the Windows package.

Hyperfocal does not modify these binaries, does not alter their copyright,
trademark or patent notices, and does not use Microsoft's trademarks in its own
name or in any way suggesting Microsoft endorsement.

### LibRaw — used under CDDL-1.0

Camera-raw decoding. LibRaw is dual-licensed `LGPL-2.1-only OR CDDL-1.0`;
**Hyperfocal uses it under the Common Development and Distribution License,
Version 1.0 (CDDL-1.0).** No LibRaw source files are modified. Full text in
[`licenses/CDDL-1.0.txt`](https://github.com/ethannicholas/hyperfocal/tree/main/licenses/CDDL-1.0.txt).

> Copyright © LibRaw LLC (info@libraw.org). LibRaw uses code from dcraw,
> © Dave Coffin.

The `dng-lossy` build option additionally uses libjpeg-turbo (below); it does
not enable LibRaw's optional Adobe-DNG-SDK integration.

### OpenCV 4 — Apache-2.0

Feature detection (SIFT) and homography registration (modules core, imgproc,
features2d, calib3d, video). License: `Apache-2.0` (patent grant per §3). Full
text in [`licenses/Apache-2.0.txt`](https://github.com/ethannicholas/hyperfocal/tree/main/licenses/Apache-2.0.txt).

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

### giflib

Animated GIF writing for the rocking-animation export. Version 6.1.3, linked
dynamically. License: `MIT`.

> The GIFLIB distribution is Copyright © 1997 Eric S. Raymond.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.

### OpenCombine

`ObservableObject`/`@Published` on non-Apple platforms. License: `MIT`.

> Copyright © 2019 Sergej Jaskiewicz and OpenCombine contributors.

### XZ Utils (liblzma)

LZMA decompression, linked by libtiff for its LZMA codec. License: `0BSD`.

> Copyright © The Tukaani Project (https://tukaani.org/xz/). Permission to use,
> copy, modify, and/or distribute this software for any purpose with or without
> fee is hereby granted.

### wgpu-native — used under MIT

The Windows/Linux GPU compute backend. The package ships `wgpu_native.dll`,
the prebuilt release pinned in
[`Scripts/fetch-wgpu.sh`](https://github.com/ethannicholas/hyperfocal/tree/main/Scripts/fetch-wgpu.sh),
unmodified. wgpu-native is dual-licensed `MIT OR Apache-2.0`; **Hyperfocal uses
it under the MIT License.**

> Copyright © The gfx-rs developers.

It is a Rust library, so the DLL statically links its whole dependency graph —
140 components at the pinned version, including wgpu-core, naga, ash (Vulkan)
and the D3D12 bindings. **Every one of them is permissive** (predominantly
`MIT OR Apache-2.0`, with a few under MIT, Apache-2.0, BSD-2-Clause,
BSD-3-Clause, ISC, Zlib, CC0-1.0 or Unlicense); nothing in the graph is
copyleft. Because the upstream release archive carries no license text of its
own, the complete component list — each with its version, SPDX expression, the
arm elected here, and the verbatim license texts — is generated by
[`Scripts/gen-wgpu-notices.py`](https://github.com/ethannicholas/hyperfocal/tree/main/Scripts/gen-wgpu-notices.py)
into
[`licenses/wgpu-native-ThirdPartyNotices.txt`](https://github.com/ethannicholas/hyperfocal/tree/main/licenses/wgpu-native-ThirdPartyNotices.txt),
which is bundled with the Windows package. That file is regenerated whenever
the pin moves, and `--check` fails the build if the two disagree.

macOS builds contain none of this: they fuse on Metal, and the bridge that
links wgpu is never shipped with the macOS app.

### Mesa 3D — llvmpipe software OpenGL

The Windows package ships `opengl32sw.dll`, staged by `windeployqt`: Mesa's
llvmpipe software rasterizer, which Qt falls back to when a machine offers no
usable hardware OpenGL. It is kept deliberately — the package targets arbitrary
Store machines, including virtual ones with no GPU driver — and is unmodified.
License: `MIT`. Mesa embeds LLVM (`Apache-2.0 WITH LLVM-exception`) as
llvmpipe's JIT.

> Copyright © 1999–2016 Brian Paul and the Mesa 3D contributors. All Rights
> Reserved.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in
> the Software without restriction … The above copyright notice and this
> permission notice shall be included in all copies or substantial portions of
> the Software.

### Swift runtime — Apache-2.0 WITH Runtime Library Exception

The Windows package ships the Swift runtime redistributable beside the
executable (`swiftCore.dll`, `swift_Concurrency.dll`, `swift_RegexParser.dll`,
`swift_StringProcessing.dll`, `swiftCRT.dll`, `swiftDispatch.dll`,
`swiftWinSDK.dll`, `Foundation.dll`, `FoundationEssentials.dll`,
`FoundationInternationalization.dll`, `dispatch.dll`, `BlocksRuntime.dll`), the
supported way to run a Swift binary on a machine without a toolchain.

> Copyright © Apple Inc. and the Swift project authors.

The Runtime Library Exception waives the attribution requirement for compiled
forms of the runtime, so this entry is courtesy rather than obligation — the
same reasoning the swift-argument-parser entry records. It is listed because a
reader inspecting the package should be able to account for every binary in it.

### International Components for Unicode (ICU)

`_FoundationICU.dll` and `icuuc.dll` ship as part of the Swift runtime above;
Foundation uses them for collation, normalization and locale data. ICU is **not**
covered by the Swift Runtime Library Exception and carries its own attribution
requirement. License: `Unicode-3.0` (Unicode License v3).

> Copyright © 1991–2024 Unicode, Inc. All rights reserved.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> the Unicode data files and any associated documentation (the "Data Files") or
> Unicode software and any associated documentation (the "Software") to deal in
> the Data Files or Software without restriction … provided that either (a) this
> copyright and permission notice appear with all copies of the Data Files or
> Software, or (b) this copyright and permission notice appear in associated
> Documentation.

### Microsoft Visual C++ runtime — Distributable Code

`MSVCP140.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll` and `CONCRT140.dll`
ship app-locally (they arrive with the Swift runtime redistributable, and
`Scripts/package-windows.ps1` asserts their presence rather than letting
`windeployqt` drop a `vc_redist` installer into the payload). They are
**Microsoft binaries, not covered by Hyperfocal's MIT license**, redistributed
as "Distributable Code" under the Microsoft Software License Terms for Visual
Studio, which permit app-local deployment of the C++ runtime files.

> Copyright © Microsoft Corporation. All rights reserved.
