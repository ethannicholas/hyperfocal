# Third-party notices

Hyperfocal itself is MIT-licensed (see [LICENSE](LICENSE)). It ships with the
following third-party components:

## Adobe DNG SDK 1.7.1

`Vendor/dng_sdk/` vendors the Adobe DNG SDK (linear DNG export). It is used
under the DNG SDK License Agreement — see
[`Vendor/dng_sdk/dng_sdk_license.txt`](Vendor/dng_sdk/dng_sdk_license.txt)
for the full text. Per-file notices are retained in the vendored sources.

> Copyright © 2006–2023 Adobe Systems Incorporated. All Rights Reserved.
>
> This product includes DNG technology under license by Adobe Systems
> Incorporated.

Adobe and the DNG logo are trademarks or registered trademarks of Adobe
Systems Incorporated in the United States and/or other countries.

## swift-argument-parser

The command-line tool (`hyperfocal-cli`, not shipped in the app bundle) uses
[swift-argument-parser](https://github.com/apple/swift-argument-parser),
© Apple Inc., licensed under the Apache License 2.0.

## Build-time tools (not distributed)

[XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT) generates the Xcode
project; it is not part of any distributed binary.
