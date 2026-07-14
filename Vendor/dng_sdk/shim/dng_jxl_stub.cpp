// Link-level stubs for the JPEG XL functions declared in dng_jxl.h.
//
// dng_jxl.cpp requires libjxl (plus brotli and highway), which we do not use:
// Hyperfocal writes 16-bit LinearRaw DNGs, whose only legal compression is
// lossless JPEG — implemented natively by the SDK in dng_lossless_jpeg.cpp.
// These stubs satisfy the linker for the JXL code paths, which are only
// reachable when explicitly requesting JXL compression (we never do).

#include "dng_jxl.h"

#include "dng_exceptions.h"
#include "dng_host.h"
#include "dng_image.h"
#include "dng_info.h"
#include "dng_pixel_buffer.h"
#include "dng_stream.h"

/*****************************************************************************/

bool ParseJXL (dng_host & /* host */,
			   dng_stream & /* stream */,
			   dng_info & /* info */,
			   bool /* supportBasicCodeStream */,
			   bool /* supportContainer */)
	{
	return false;  // not a JXL stream we can parse
	}

/*****************************************************************************/

dng_jxl_decoder::~dng_jxl_decoder ()
	{
	}

void dng_jxl_decoder::Decode (dng_host & /* host */,
							  dng_stream & /* stream */)
	{
	ThrowNotYetImplemented ("JPEG XL support not built");
	}

void dng_jxl_decoder::ProcessExifBox (dng_host & /* host */,
									  const std::vector<uint8> & /* data */)
	{
	}

void dng_jxl_decoder::ProcessXMPBox (dng_host & /* host */,
									 const std::vector<uint8> & /* data */)
	{
	}

void dng_jxl_decoder::ProcessBox (dng_host & /* host */,
								  const dng_string & /* name */,
								  const std::vector<uint8> & /* data */)
	{
	}

/*****************************************************************************/

void EncodeJXL_Tile (dng_host & /* host */,
					 dng_stream & /* stream */,
					 const dng_pixel_buffer & /* buffer */,
					 const dng_jxl_color_space_info & /* colorSpaceInfo */,
					 const dng_jxl_encode_settings & /* settings */)
	{
	ThrowNotYetImplemented ("JPEG XL support not built");
	}

void EncodeJXL_Tile (dng_host & /* host */,
					 dng_stream & /* stream */,
					 const dng_image & /* image */,
					 const dng_jxl_color_space_info & /* colorSpaceInfo */,
					 const dng_jxl_encode_settings & /* settings */)
	{
	ThrowNotYetImplemented ("JPEG XL support not built");
	}

void EncodeJXL_Container (dng_host & /* host */,
						  dng_stream & /* stream */,
						  const dng_image & /* image */,
						  const dng_jxl_encode_settings & /* settings */,
						  const dng_jxl_color_space_info & /* colorSpaceInfo */,
						  const dng_metadata * /* metadata */,
						  const bool /* includeExif */,
						  const bool /* includeXMP */,
						  const bool /* includeIPTC */,
						  const dng_bmff_box_list * /* additionalBoxes */)
	{
	ThrowNotYetImplemented ("JPEG XL support not built");
	}

void EncodeJXL_Container (dng_host & /* host */,
						  dng_stream & /* stream */,
						  const dng_pixel_buffer & /* buffer */,
						  const dng_jxl_encode_settings & /* settings */,
						  const dng_jxl_color_space_info & /* colorSpaceInfo */,
						  const dng_metadata * /* metadata */,
						  const bool /* includeExif */,
						  const bool /* includeXMP */,
						  const bool /* includeIPTC */,
						  const dng_bmff_box_list * /* additionalBoxes */)
	{
	ThrowNotYetImplemented ("JPEG XL support not built");
	}

/*****************************************************************************/

real32 JXLQualityToDistance (uint32 /* quality */)
	{
	return 0.0f;
	}

dng_jxl_encode_settings * JXLQualityToSettings (uint32 /* quality */)
	{
	return new dng_jxl_encode_settings;
	}

/*****************************************************************************/

void PreviewColorSpaceToJXLEncoding (const PreviewColorSpaceEnum /* colorSpace */,
									 const uint32 /* planes */,
									 dng_jxl_color_space_info & /* info */)
	{
	}

/*****************************************************************************/

bool SupportsJXL (const dng_image & /* image */)
	{
	return false;
	}
