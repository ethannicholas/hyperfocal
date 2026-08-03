// Target-internal surface shared between the shim's translation units. NOT part
// of the C ABI — that is include/cimaging.h, the only header the Swift side
// sees. This one exists so video.cpp can reuse the colour management in
// cimaging.cpp without pulling <windows.h> into that file (its macros collide
// with libtiff/OpenCV/std, which is also why the Media Foundation writer is a
// translation unit of its own).
#ifndef CIMAGING_PRIV_H
#define CIMAGING_PRIV_H

// In-place conversion of `count` interleaved RGBA Float32 pixels from the
// Display P3 working space into `colorspace` ("p3", "srgb", "prophoto").
// False if the lcms2 transform could not be built.
bool hfConvertFromP3(float* rgba, int count, const char* colorspace);

#endif // CIMAGING_PRIV_H
