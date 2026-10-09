// Purpose: Keeps screenshot pins alive as draggable always-on-top image windows.

#pragma once

#include "imaging.h"

#include <d2d1.h>

#include <memory>

namespace space {

class PinnedImageWindow;

class PinnedImageController {
public:
    static constexpr size_t kMaxPinnedImages = 5;

    PinnedImageController();
    ~PinnedImageController();

    struct Result {
        bool didEvict = false;
        size_t count = 0;
    };

    // Pins `image` with its top-left corner at `origin` (screen pixels), sized for a
    // selection of `selectionPixels` on a monitor at `scale` (DPI / 96).
    Result Pin(imaging::Bitmap image, POINT origin, SIZE selectionPixels, float scale);

    // Size in DIPs: no larger than 720 x 520, no smaller than 80 x 60.
    static D2D1_SIZE_F DisplaySize(D2D1_SIZE_F selectionDips);
    // The most pixels a pin can show: its on-screen size. Pins cannot be resized, so
    // keeping more only holds memory while the pin stays up.
    static uint64_t MaxPixelCount(SIZE selectionPixels, float scale);

private:
    void Remove(PinnedImageWindow* window);

    std::vector<std::unique_ptr<PinnedImageWindow>> windows_;
};

}  // namespace space
