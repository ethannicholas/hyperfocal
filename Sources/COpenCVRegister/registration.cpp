// macOS-only OpenCV registration for the Phase 1.5 A/B. Byte-for-byte the same
// SIFT + ratio-test + RANSAC-findHomography recipe as the Linux backend
// (`hf_register`, Sources/CImaging/cimaging.cpp) — keep the two in step until
// the A/B decides whether macOS also adopts OpenCV, at which point they merge.
#include "copencvregister.h"

// SIFT/BFMatcher and findHomography/RANSAC moved modules between OpenCV 4
// (Linux: features2d.hpp / calib3d.hpp) and OpenCV 5 (macOS Homebrew:
// features.hpp / geometry/3d.hpp). Pick the header that exists so this isn't
// pinned to one release's layout. (The umbrella opencv.hpp gates its 3d
// include on the module being built, so findHomography isn't reliably there.)
#include <opencv2/core.hpp>
#if __has_include(<opencv2/features.hpp>)
#include <opencv2/features.hpp>        // OpenCV 5
#else
#include <opencv2/features2d.hpp>      // OpenCV 4
#endif
#if __has_include(<opencv2/geometry/3d.hpp>)
#include <opencv2/geometry/3d.hpp>     // OpenCV 5
#else
#include <opencv2/calib3d.hpp>         // OpenCV 4
#endif

#include <vector>

extern "C" hfr_status hfr_register(int w, int h,
                                   const uint8_t* fixed, const uint8_t* moving,
                                   float* out_h) {
    try {
        cv::Mat fixedM(h, w, CV_8U, (void*)fixed);
        cv::Mat movingM(h, w, CV_8U, (void*)moving);
        // SIFT: scale-space extrema are localized to sub-pixel, so the fitted
        // homography is markedly more precise than ORB's FAST corners — and
        // feature matching (unlike dense ECC) survives the appearance change
        // between focus levels that a focus stack is made of.
        //
        // Feature cap: gradient-magnitude frames are feature-dense (50-70k
        // keypoints on a 4K stack), and BFMatcher's cost is quadratic in
        // them — 200+ seconds per pair, of which ~1300 matches survived the
        // ratio test. The cap keeps the strongest N by response; hundreds of
        // ratio-test survivors remain, which is all RANSAC needs. (2000
        // matches the Linux/Windows backend's measured-neutral cap.)
        cv::Ptr<cv::SIFT> sift = cv::SIFT::create(2000);
        std::vector<cv::KeyPoint> kpF, kpM;
        cv::Mat descF, descM;
        sift->detectAndCompute(fixedM, cv::noArray(), kpF, descF);
        sift->detectAndCompute(movingM, cv::noArray(), kpM, descM);
        if (descF.empty() || descM.empty() || kpF.size() < 4 || kpM.size() < 4)
            return hfr_fail;
        cv::BFMatcher matcher(cv::NORM_L2);
        std::vector<std::vector<cv::DMatch>> knn;
        matcher.knnMatch(descM, descF, knn, 2);   // query = moving, train = fixed
        std::vector<cv::Point2f> ptsM, ptsF;
        for (auto& m : knn) {
            if (m.size() < 2) continue;
            if (m[0].distance < 0.75f * m[1].distance) {
                ptsM.push_back(kpM[m[0].queryIdx].pt);
                ptsF.push_back(kpF[m[0].trainIdx].pt);
            }
        }
        if (ptsM.size() < 4) return hfr_fail;
        cv::Mat H = cv::findHomography(ptsM, ptsF, cv::RANSAC, 3.0);
        if (H.empty()) return hfr_fail;
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                out_h[r * 3 + c] = (float)H.at<double>(r, c);
        return hfr_ok;
    } catch (...) { return hfr_fail; }
}
