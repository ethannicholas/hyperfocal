// C shim over the Adobe DNG SDK: write a Linear DNG (demosaiced 16-bit linear
// RGB, LinearRaw) whose camera space is declared as linear sRGB, with lossless
// JPEG compression and an embedded preview.

#include "dng_shim.h"

#include "dng_auto_ptr.h"
#include "dng_camera_profile.h"
#include "dng_color_space.h"
#include "dng_date_time.h"
#include "dng_exceptions.h"
#include "dng_exif.h"
#include "dng_file_stream.h"
#include "dng_host.h"
#include "dng_image_writer.h"
#include "dng_matrix.h"
#include "dng_negative.h"
#include "dng_pixel_buffer.h"
#include "dng_preview.h"
#include "dng_rational.h"
#include "dng_simple_image.h"
#include "dng_string.h"
#include "dng_tag_values.h"

#include <cstring>
#include <exception>
#include <memory>

namespace {

void copyError(const char *message, char *errbuf, int32_t errbufLen)
	{
	if (errbuf && errbufLen > 0)
		{
		std::strncpy (errbuf, message, size_t (errbufLen - 1));
		errbuf[errbufLen - 1] = 0;
		}
	}

}  // namespace

extern "C" int hyperfocal_write_linear_dng(const uint16_t *rgb,
										int32_t width,
										int32_t height,
										const uint8_t *previewRGB,
										int32_t previewWidth,
										int32_t previewHeight,
										const char *path,
										const char *cameraModel,
										const hyperfocal_dng_metadata *metadata,
										char *errbuf,
										int32_t errbufLen)
	{

	try
		{

		dng_host host;

		host.SetSaveDNGVersion (dngVersion_1_4_0_0);
		host.SetSaveLinearDNG (true);

		const dng_rect bounds (height, width);

		// Full-resolution image.

		AutoPtr<dng_image> image (new dng_simple_image (bounds, 3, ttShort,
														host.Allocator ()));

		{
		dng_pixel_buffer buffer;
		buffer.fArea      = bounds;
		buffer.fPlane     = 0;
		buffer.fPlanes    = 3;
		buffer.fRowStep   = intptr_t (width) * 3;
		buffer.fColStep   = 3;
		buffer.fPlaneStep = 1;
		buffer.fPixelType = ttShort;
		buffer.fPixelSize = 2;
		buffer.fData      = const_cast<uint16_t *> (rgb);
		image->Put (buffer);
		}

		// Negative.

		AutoPtr<dng_negative> negative (host.Make_dng_negative ());

		negative->SetModelName (cameraModel);
		negative->SetLocalName (cameraModel);

		negative->SetColorChannels (3);
		negative->SetColorKeys (colorKeyRed, colorKeyGreen, colorKeyBlue);

		negative->SetWhiteLevel (65535);
		negative->SetBlackLevel (0);

		negative->SetDefaultScale (dng_urational (1, 1), dng_urational (1, 1));
		negative->SetDefaultCropOrigin (0, 0);
		negative->SetDefaultCropSize (width, height);
		negative->SetActiveArea (bounds);

		negative->SetBaselineExposure (metadata ? metadata->baselineExposure : 0.0);
		negative->SetBaselineNoise (1.0);
		negative->SetBaselineSharpness (1.0);

		if (metadata && metadata->hasNeutral)
			{
			negative->SetCameraNeutral (dng_vector_3 (metadata->asShotNeutral[0],
													  metadata->asShotNeutral[1],
													  metadata->asShotNeutral[2]));
			}
		else
			{
			negative->SetCameraNeutral (dng_vector_3 (1.0, 1.0, 1.0));
			}

		// EXIF carried over from the source frames.

		if (metadata)
			{

			dng_exif *exif = negative->GetExif ();

			if (metadata->make)
				{
				exif->fMake.Set (metadata->make);
				}

			if (metadata->model)
				{
				exif->fModel.Set (metadata->model);
				}

			if (metadata->lensName)
				{
				exif->fLensName.Set (metadata->lensName);
				}

			if (metadata->exposureTime > 0.0)
				{
				exif->SetExposureTime (metadata->exposureTime);
				}

			if (metadata->fNumber > 0.0)
				{
				exif->SetFNumber (metadata->fNumber);
				}

			if (metadata->focalLengthMM > 0.0)
				{
				exif->fFocalLength.Set_real64 (metadata->focalLengthMM, 1000);
				}

			if (metadata->isoSpeed > 0)
				{
				exif->fISOSpeedRatings[0] = uint32 (metadata->isoSpeed);
				}

			if (metadata->dateTimeOriginal)
				{
				dng_date_time dt;
				if (dt.Parse (metadata->dateTimeOriginal))
					{
					dng_date_time_info info;
					info.SetDateTime (dt);
					exif->fDateTimeOriginal = info;
					exif->fDateTime = info;
					}
				}

			}

		// Camera space = linear Display P3 (the pipeline's working primaries):
		// ColorMatrix1 maps XYZ (D65) to camera, and ForwardMatrix1 maps
		// white-balanced camera to XYZ (D50) — Bradford(D65→D50) × P3→XYZ —
		// so ACR renders our primaries exactly instead of deriving the
		// white-point mapping from its own adaptation heuristics. Both must
		// match DNGWriter.{xyzToCamera,forwardMatrix} on the Swift side.
		//
		// POLICY: raw processors resolve profiles by name and content
		// fingerprint together — if either matrix ever changes after DNGs
		// have been distributed, RENAME the profile (…"v2"), or catalogs
		// holding older exports show "profile missing" style warnings.

		AutoPtr<dng_camera_profile> profile (new dng_camera_profile);

		profile->SetName ("Hyperfocal Linear P3");

		dng_matrix_3by3 xyzToCamera ( 2.4934969, -0.9313836, -0.4027108,
									 -0.8294890,  1.7626641,  0.0236247,
									  0.0358458, -0.0761724,  0.9568845);

		dng_matrix_3by3 forwardMatrix ( 0.5150749,  0.2919397,  0.1571791,
										0.2411702,  0.6922355,  0.0665900,
									   -0.0010486,  0.0418841,  0.7845459);

		profile->SetColorMatrix1 (xyzToCamera);
		profile->SetForwardMatrix1 (forwardMatrix);
		profile->SetCalibrationIlluminant1 (lsD65);

		negative->AddProfile (profile);

		negative->SetStage1Image (image);

		negative->SynchronizeMetadata ();

		// Preview.

		dng_preview_list previewList;

		if (previewRGB && previewWidth > 0 && previewHeight > 0)
			{

			const dng_rect previewBounds (previewHeight, previewWidth);

			AutoPtr<dng_image> previewImage (new dng_simple_image (previewBounds, 3, ttByte,
																   host.Allocator ()));

			{
			dng_pixel_buffer buffer;
			buffer.fArea      = previewBounds;
			buffer.fPlane     = 0;
			buffer.fPlanes    = 3;
			buffer.fRowStep   = intptr_t (previewWidth) * 3;
			buffer.fColStep   = 3;
			buffer.fPlaneStep = 1;
			buffer.fPixelType = ttByte;
			buffer.fPixelSize = 1;
			buffer.fData      = const_cast<uint8_t *> (previewRGB);
			previewImage->Put (buffer);
			}

			AutoPtr<dng_preview> preview (new dng_image_preview);

			preview->fInfo.fColorSpace = previewColorSpace_sRGB;

			preview->SetImage (host, previewImage);

			previewList.Append (preview);

			}

		// Write, compressed (lossless JPEG for 16-bit integer data).

		dng_file_stream stream (path, true);

		dng_image_writer writer;

		writer.WriteDNG (host, stream, *negative,
						 previewList.Count () ? &previewList : nullptr,
						 dngVersion_1_4_0_0,
						 false /* uncompressed */);

		return 0;

		}

	catch (const dng_exception &except)
		{
		char message[64];
		snprintf (message, sizeof (message), "DNG SDK error %d", int (except.ErrorCode ()));
		copyError (message, errbuf, errbufLen);
		return int (except.ErrorCode ());
		}

	catch (const std::exception &except)
		{
		copyError (except.what (), errbuf, errbufLen);
		return -1;
		}

	catch (...)
		{
		copyError ("unknown error", errbuf, errbufLen);
		return -2;
		}

	}
