// Purpose: Watches the Windows clipboard, keeps a bounded text and image history on disk,
// and puts entries back on the clipboard.

#pragma once

#include "common.h"

namespace space {

struct ClipboardItem {
    std::wstring id;
    std::wstring text;
    std::wstring imageFileName;
    std::wstring imageFingerprint;
    std::wstring sourceApplicationName;
    double createdAt = 0;
    double updatedAt = 0;

    bool IsImage() const { return !imageFileName.empty(); }
};

class ClipboardStore {
public:
    static constexpr size_t kMaxTextBytes = 100'000;
    static constexpr size_t kMaxImageBytes = 50'000'000;
    static constexpr uint64_t kMaxImagePixels = 16'000'000;
    static constexpr UINT_PTR kRetryTimerId = 0x5101;

    ClipboardStore(size_t maxItemCount = 50, double retentionSeconds = 24 * 60 * 60);

    // Registers `window` for WM_CLIPBOARDUPDATE; the window forwards those, and the
    // retry timer, to the Handle* methods.
    void StartMonitoring(HWND window);
    void StopMonitoring();
    void HandleClipboardUpdate();
    void HandleRetryTimer();

    const std::vector<ClipboardItem>& Items() const { return items_; }
    const ClipboardItem* Find(const std::wstring& id) const;
    const std::wstring& LastError() const { return lastError_; }
    void ClearError();

    void AddText(const std::wstring& text, const std::wstring& source, double now);
    // `encoded` is PNG or JPEG. The fingerprint is of the data as it arrived, so the same
    // image copied again is recognised even after a DIB was re-encoded as PNG.
    bool AddImage(const std::vector<uint8_t>& encoded, const std::wstring& fingerprint,
                  const std::wstring& source, double now);

    void Delete(const std::wstring& id);
    std::wstring ImagePath(const ClipboardItem& item) const;

    bool CopyToClipboard(const std::wstring& id);
    void Promote(const std::wstring& id);

    bool SetClipboardText(const std::wstring& text);
    bool SetClipboardImage(const std::vector<uint8_t>& encoded);

    void PruneHistory(double now);

    std::function<void()> onChange;

private:
    struct ClipboardImage {
        std::vector<uint8_t> bytes;  // as the clipboard holds it: PNG, JPEG or a DIB
        bool isDib = false;
    };

    void ReadOpenClipboard();
    std::optional<ClipboardImage> EncodedImageOnOpenClipboard() const;
    bool HasPrivacyMarkerOnOpenClipboard() const;
    std::wstring SourceApplicationName() const;
    bool AddDib(const std::vector<uint8_t>& dib, const std::wstring& source, double now);

    std::wstring StoreImageFile(const std::vector<uint8_t>& encoded, const std::wstring& id);
    void RemoveImageItemsMatching(const std::wstring& fingerprint, const std::vector<uint8_t>* bytes);
    void DeleteImageFile(const ClipboardItem& item);
    void ClearClipboardIfCurrentItem(const ClipboardItem& item);
    std::optional<std::vector<uint8_t>> ImageBytes(const ClipboardItem& item) const;

    void Load();
    void PreserveUnreadableHistory(const std::wstring& reason);
    void Save();
    void Changed();

    HWND window_ = nullptr;
    std::vector<ClipboardItem> items_;
    std::wstring lastError_;
    std::wstring storagePath_;
    std::wstring imageDirectory_;
    size_t maxItemCount_;
    double retentionSeconds_;
    DWORD lastSequence_ = 0;
    int retryCount_ = 0;

    UINT pngFormat_ = 0;
    UINT jfifFormat_ = 0;
    UINT excludeFormat_ = 0;
    UINT historyFormat_ = 0;
    UINT viewerIgnoreFormat_ = 0;
};

}  // namespace space
