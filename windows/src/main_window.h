// Purpose: The floating clipboard and shortcuts panel, custom drawn with Direct2D: history
// cards with keyboard navigation and paste-on-pick, and the shortcut recorders and status
// rows.

#pragma once

#include "clipboard_store.h"
#include "common.h"
#include "graphics.h"
#include "hotkeys.h"

#include <d2d1.h>
#include <dwrite.h>

#include <deque>
#include <map>
#include <memory>

namespace space {

class App;
class ThumbnailLoader;

class MainWindow {
public:
    explicit MainWindow(App& app);
    ~MainWindow();

    void Show();
    // Returns whether a visible panel was taken off screen.
    bool Hide();
    bool IsVisible() const;
    void Refresh();

private:
    enum class Tab { History, Shortcuts };

    enum class HitKind {
        None,
        Close,
        Tab,
        Quit,
        DismissError,
        Card,
        CardCopy,
        CardDelete,
        ShortcutButton,
        LoginToggle,
        LoginCheck,
        DismissLogin,
        DismissCapture,
        DismissRecording,
        ScrollThumb,
    };

    struct HitId {
        HitKind kind = HitKind::None;
        int index = 0;
        std::wstring itemId;

        bool operator==(const HitId& other) const {
            return kind == other.kind && index == other.index && itemId == other.itemId;
        }
        bool operator!=(const HitId& other) const { return !(*this == other); }
    };

    struct HitRegion {
        D2D1_RECT_F rect;
        HitId id;
        std::wstring tooltip;
    };

    struct CardLayout {
        std::wstring id;
        float top = 0;
        float height = 0;
    };

    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);

    bool Create();
    void PlaceOnScreen();
    void StartShowAnimation();
    void StepShowAnimation();

    // Drawing.
    void Paint();
    bool EnsureTarget();
    void DiscardDeviceResources();
    float BannerHeight() const;
    D2D1_RECT_F ContentRect() const;
    void DrawBanner(gfx::Painter& painter);
    void DrawTabBar(gfx::Painter& painter);
    void DrawHistory(gfx::Painter& painter, const D2D1_RECT_F& content);
    void DrawCard(gfx::Painter& painter, const ClipboardItem& item, const D2D1_RECT_F& rect, bool selected);
    void DrawImagePreview(gfx::Painter& painter, const ClipboardItem& item, const D2D1_RECT_F& rect);
    void DrawShortcuts(gfx::Painter& painter, const D2D1_RECT_F& content);
    float DrawRecorderButton(gfx::Painter& painter, HotKeyCommand command, float right, float centerY, bool compact);
    float DrawStatusRow(gfx::Painter& painter, float top, float left, float right, wchar_t glyph,
                        D2D1_COLOR_F color, const std::wstring& text, HitKind dismiss);
    void DrawButton(gfx::Painter& painter, const D2D1_RECT_F& rect, const std::wstring& title, HitId id,
                    bool emphasized = false);
    void DrawScrollbar(gfx::Painter& painter, const D2D1_RECT_F& viewport);
    void AddHit(const D2D1_RECT_F& rect, HitId id, std::wstring tooltip = {});

    // Measurement.
    std::vector<CardLayout> LayoutCards(float width);
    float CardHeight(const ClipboardItem& item, float width);
    float TextHeight(const std::wstring& text, IDWriteTextFormat* format, float width, int maxLines);
    std::optional<D2D1_SIZE_U> ImageSize(const ClipboardItem& item);

    // Interaction.
    std::optional<HitRegion> HitAt(float x, float y) const;
    void MouseMove(float x, float y);
    void MouseDown(float x, float y);
    void MouseUp(float x, float y);
    void Activate(const HitId& id);
    void Wheel(int delta);
    void KeyDown(UINT key);
    void MoveSelection(int offset);
    void Pick(const std::wstring& id);
    void SelectTab(Tab tab);
    void ScrollTo(float offset, bool animated);
    void ScrollSelectionIntoView();
    void StepScrollAnimation();
    float MaxScroll() const;
    void UpdateTooltip(const std::optional<HitRegion>& region);

    // Shortcut recording.
    void StartRecording(HotKeyCommand command);
    void FinishRecording();
    void CancelRecording();
    void HandleRecordedKey(UINT virtualKey, UINT modifiers);
    static LRESULT CALLBACK KeyboardHook(int code, WPARAM wParam, LPARAM lParam);

    // Thumbnails.
    void RequestThumbnail(const ClipboardItem& item, const D2D1_RECT_F& rect);
    void ThumbnailReady(LPARAM payload);
    void PruneThumbnails();

    App& app_;
    HWND hwnd_ = nullptr;
    HWND tooltip_ = nullptr;
    float scale_ = 1.0f;
    ComPtr<ID2D1HwndRenderTarget> target_;

    Tab tab_ = Tab::History;
    std::wstring selectedId_;
    float scroll_[2] = {0, 0};
    float contentHeight_[2] = {0, 0};
    float viewportHeight_ = 0;

    std::vector<HitRegion> hits_;
    HitId hover_;
    HitId pressed_;
    bool trackingMouse_ = false;
    std::optional<float> thumbDragOffset_;

    HWND previousForeground_ = nullptr;
    ULONGLONG showAnimationStart_ = 0;
    POINT targetPosition_{};

    float scrollAnimationFrom_ = 0;
    float scrollAnimationTo_ = 0;
    ULONGLONG scrollAnimationStart_ = 0;

    std::optional<HotKeyCommand> recordingCommand_;
    static HHOOK keyboardHook_;
    static HWND hookTarget_;

    std::unique_ptr<ThumbnailLoader> thumbnailLoader_;
    std::map<std::wstring, ComPtr<ID2D1Bitmap>> thumbnails_;
    std::deque<std::wstring> thumbnailOrder_;
    std::map<std::wstring, bool> thumbnailRequested_;
    std::map<std::wstring, D2D1_SIZE_U> imageSizes_;
    std::map<std::wstring, float> textHeights_;
    float textHeightWidth_ = 0;
};

}  // namespace space
