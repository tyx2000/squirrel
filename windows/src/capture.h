// Purpose: Area capture: freezes the screen under the pointer, lets the user select,
// annotate and sample colours over it, then copies the result to the clipboard and history
// or pins it.

#pragma once

#include "imaging.h"
#include "pinned_image.h"

#include <d2d1.h>

#include <memory>

namespace space {

class ClipboardStore;

enum class AnnotationTool { Rectangle, Line, Arrow };

struct Annotation {
    AnnotationTool tool;
    D2D1_POINT_2F start;
    D2D1_POINT_2F end;
};

enum class CaptureOutputAction { Pin, Copy };

enum class ResizeHandle { TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left };

struct ResizeHandleMetrics {
    D2D1_SIZE_F cornerSize;
    float edgeThickness;
    float edgeLength;
    float hitOutset;
};

// Handle geometry in top-down coordinates, shared by drawing and hit testing.
namespace handles {
std::vector<std::pair<ResizeHandle, D2D1_RECT_F>> Rects(const D2D1_RECT_F& rect, const ResizeHandleMetrics& metrics);
std::optional<ResizeHandle> HandleAt(D2D1_POINT_2F point, const D2D1_RECT_F& rect, const ResizeHandleMetrics& metrics);
}  // namespace handles

// The frozen screen: top-down BGRA pixels of one monitor, alpha forced opaque.
struct ScreenSnapshot {
    RECT monitorRect{};
    float scale = 1.0f;  // monitor DPI / 96
    imaging::Bitmap pixels;
};

class CaptureOverlay;

class CaptureService {
public:
    static constexpr UINT_PTR kSettleTimerId = 0x5301;
    static constexpr UINT_PTR kFinishTimerId = 0x5302;

    CaptureService(ClipboardStore& store, std::function<void(bool)> setPresentationSuppressed,
                   std::function<bool()> hidePanel);
    ~CaptureService();

    void Attach(HWND timerWindow);
    void StartAreaCapture(std::function<void(const std::wstring&)> onFailure);
    // Returns whether `timerId` was one of the capture timers.
    bool HandleTimer(UINT_PTR timerId);

    const std::wstring& LastMessage() const { return lastMessage_; }
    void ClearMessage();
    std::function<void()> onChange;

private:
    struct PendingResult {
        CaptureOutputAction action;
        D2D1_RECT_F selection;
        std::vector<Annotation> annotations;
    };

    void ShowOverlay();
    void FinishOverlay();
    void Complete(const PendingResult& result);
    void Fail(const std::wstring& message);
    void SetMessage(std::wstring message);

    ClipboardStore& store_;
    std::function<void(bool)> setPresentationSuppressed_;
    std::function<bool()> hidePanel_;
    std::function<void(const std::wstring&)> onFailure_;
    HWND timerWindow_ = nullptr;
    bool isPreparing_ = false;
    std::unique_ptr<CaptureOverlay> overlay_;
    std::unique_ptr<ScreenSnapshot> snapshot_;
    std::optional<PendingResult> pending_;
    PinnedImageController pins_;
    std::wstring lastMessage_;
};

// Renders `region` (crop of the snapshot at `origin`) into an independent image with the
// annotations drawn on top, scaled down to `maxPixelCount` when it is larger.
std::optional<imaging::Bitmap> RenderCapture(const ScreenSnapshot& snapshot, const RECT& region,
                                             const std::vector<Annotation>& annotations, uint64_t maxPixelCount);

}  // namespace space
