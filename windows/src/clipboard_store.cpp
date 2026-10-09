// Purpose: Implements clipboard monitoring, history persistence and image storage.

#include "clipboard_store.h"

#include "imaging.h"
#include "json.h"

#include <shellapi.h>

#include <algorithm>
#include <cstring>
#include <unordered_set>

namespace space {

namespace {

constexpr int kMaxClipboardRetries = 10;
constexpr UINT kRetryDelayMs = 40;

std::optional<std::vector<uint8_t>> GlobalBytes(UINT format) {
    HANDLE handle = GetClipboardData(format);
    if (!handle) return std::nullopt;
    SIZE_T size = GlobalSize(handle);
    const void* data = GlobalLock(handle);
    if (!data) return std::nullopt;
    std::vector<uint8_t> bytes(static_cast<const uint8_t*>(data), static_cast<const uint8_t*>(data) + size);
    GlobalUnlock(handle);
    return bytes;
}

std::optional<std::wstring> ClipboardText() {
    HANDLE handle = GetClipboardData(CF_UNICODETEXT);
    if (!handle) return std::nullopt;
    const auto* data = static_cast<const wchar_t*>(GlobalLock(handle));
    if (!data) return std::nullopt;
    size_t maxLength = GlobalSize(handle) / sizeof(wchar_t);
    size_t length = 0;
    while (length < maxLength && data[length] != L'\0') ++length;
    std::wstring text(data, length);
    GlobalUnlock(handle);
    return text;
}

bool SetGlobalData(UINT format, const void* data, size_t size) {
    HGLOBAL global = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!global) return false;
    void* target = GlobalLock(global);
    if (!target) {
        GlobalFree(global);
        return false;
    }
    std::memcpy(target, data, size);
    GlobalUnlock(global);
    if (!SetClipboardData(format, global)) {
        GlobalFree(global);
        return false;
    }
    return true;
}

// Another process may hold the clipboard open for a moment; try briefly before failing.
bool OpenClipboardWithRetry(HWND window) {
    for (int attempt = 0; attempt < 5; ++attempt) {
        if (OpenClipboard(window)) return true;
        Sleep(10);
    }
    return false;
}

uint64_t DibPixelCount(const std::vector<uint8_t>& dib) {
    if (dib.size() < sizeof(BITMAPINFOHEADER)) return 0;
    BITMAPINFOHEADER header{};
    std::memcpy(&header, dib.data(), sizeof(header));
    uint64_t width = static_cast<uint64_t>(std::max<LONG>(header.biWidth, 1));
    uint64_t height = static_cast<uint64_t>(std::max<LONG>(std::abs(header.biHeight), 1));
    return width * height;
}

}  // namespace

ClipboardStore::ClipboardStore(size_t maxItemCount, double retentionSeconds)
    : maxItemCount_(std::max<size_t>(1, maxItemCount)), retentionSeconds_(std::max(0.0, retentionSeconds)) {
    pngFormat_ = RegisterClipboardFormatW(L"PNG");
    jfifFormat_ = RegisterClipboardFormatW(L"JFIF");
    // The markers password managers set to keep their copies out of clipboard managers
    // and out of Windows' own clipboard history.
    excludeFormat_ = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
    historyFormat_ = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
    viewerIgnoreFormat_ = RegisterClipboardFormatW(L"Clipboard Viewer Ignore");

    std::wstring directory = AppDataDirectory();
    if (!directory.empty()) {
        storagePath_ = directory + L"\\clipboard-history.json";
        imageDirectory_ = directory + L"\\ClipboardImages";
    }
    lastSequence_ = GetClipboardSequenceNumber();
    Load();
    PruneHistory(UnixNow());
}

void ClipboardStore::StartMonitoring(HWND window) {
    window_ = window;
    lastSequence_ = GetClipboardSequenceNumber();
    AddClipboardFormatListener(window);
}

void ClipboardStore::StopMonitoring() {
    if (window_) RemoveClipboardFormatListener(window_);
}

const ClipboardItem* ClipboardStore::Find(const std::wstring& id) const {
    for (const auto& item : items_) {
        if (item.id == id) return &item;
    }
    return nullptr;
}

void ClipboardStore::ClearError() {
    lastError_.clear();
    Changed();
}

void ClipboardStore::HandleClipboardUpdate() {
    DWORD sequence = GetClipboardSequenceNumber();
    if (sequence == lastSequence_) return;

    if (!OpenClipboard(window_)) {
        // Whoever changed it may still have it open; look again shortly.
        if (retryCount_ < kMaxClipboardRetries) {
            ++retryCount_;
            SetTimer(window_, kRetryTimerId, kRetryDelayMs, nullptr);
        } else {
            retryCount_ = 0;
        }
        return;
    }

    retryCount_ = 0;
    lastSequence_ = sequence;
    ReadOpenClipboard();
    CloseClipboard();
}

void ClipboardStore::HandleRetryTimer() {
    KillTimer(window_, kRetryTimerId);
    HandleClipboardUpdate();
}

bool ClipboardStore::HasPrivacyMarkerOnOpenClipboard() const {
    if (IsClipboardFormatAvailable(excludeFormat_) || IsClipboardFormatAvailable(viewerIgnoreFormat_)) return true;
    if (IsClipboardFormatAvailable(historyFormat_)) {
        auto value = GlobalBytes(historyFormat_);
        DWORD allowed = 1;
        if (value && value->size() >= sizeof(DWORD)) std::memcpy(&allowed, value->data(), sizeof(DWORD));
        if (allowed == 0) return true;
    }
    return false;
}

std::optional<ClipboardStore::ClipboardImage> ClipboardStore::EncodedImageOnOpenClipboard() const {
    for (UINT format : {pngFormat_, jfifFormat_}) {
        if (!IsClipboardFormatAvailable(format)) continue;
        auto bytes = GlobalBytes(format);
        if (bytes && !bytes->empty()) return ClipboardImage{std::move(*bytes), false};
    }
    for (UINT format : {static_cast<UINT>(CF_DIBV5), static_cast<UINT>(CF_DIB)}) {
        if (!IsClipboardFormatAvailable(format)) continue;
        auto bytes = GlobalBytes(format);
        if (bytes && bytes->size() > sizeof(BITMAPINFOHEADER)) return ClipboardImage{std::move(*bytes), true};
    }
    return std::nullopt;
}

void ClipboardStore::ReadOpenClipboard() {
    double now = UnixNow();
    if (HasPrivacyMarkerOnOpenClipboard()) return;

    std::wstring source = SourceApplicationName();

    // Encoded image data first: an app that copies a picture as PNG or JPEG means the
    // picture, whatever else it adds.
    for (UINT format : {pngFormat_, jfifFormat_}) {
        if (!IsClipboardFormatAvailable(format)) continue;
        auto bytes = GlobalBytes(format);
        if (!bytes || bytes->empty()) continue;
        if (bytes->size() > kMaxImageBytes) {
            lastError_ = L"Image too large (max 50MB)";
            Changed();
            return;
        }
        AddImage(*bytes, imaging::Sha256Hex(bytes->data(), bytes->size()), source, now);
        return;
    }

    auto text = IsClipboardFormatAvailable(CF_UNICODETEXT) ? ClipboardText() : std::nullopt;
    bool hasText = text && !IsBlank(*text);
    bool hasBitmap = IsClipboardFormatAvailable(CF_DIBV5) || IsClipboardFormatAvailable(CF_DIB);

    // Office copies a picture of the text or cells along with the text itself; that
    // copy means the text. A bitmap with no text is a picture, and comes before the
    // file-link check because some apps (WeCom for one) copy an image together with a
    // link to the file it came from.
    if (hasBitmap && !hasText) {
        auto image = EncodedImageOnOpenClipboard();
        if (image && image->isDib) AddDib(image->bytes, source, now);
        return;
    }

    // A file copy (from Explorer, for example) carries file links but no image. History
    // keeps text and images only, so it is not recorded.
    if (IsClipboardFormatAvailable(CF_HDROP)) return;

    if (text) {
        AddText(*text, source, now);
    } else {
        PruneHistory(now);
    }
}

std::wstring ClipboardStore::SourceApplicationName() const {
    HWND owner = GetClipboardOwner();
    if (!owner) owner = GetForegroundWindow();
    if (!owner) return {};

    DWORD processId = 0;
    GetWindowThreadProcessId(owner, &processId);
    if (processId == 0 || processId == GetCurrentProcessId()) return {};
    return ProcessDisplayName(processId);
}

void ClipboardStore::AddText(const std::wstring& text, const std::wstring& source, double now) {
    if (IsBlank(text)) return;
    // History preserves exact clipboard text, so enforce the byte limit on the stored
    // payload, including whitespace and multi-byte characters.
    if (WideToUtf8(text).size() > kMaxTextBytes) {
        lastError_ = L"Clipboard text too large (max 100KB)";
        Changed();
        return;
    }

    items_.erase(std::remove_if(items_.begin(), items_.end(),
                                [&](const ClipboardItem& item) { return !item.IsImage() && item.text == text; }),
                 items_.end());

    ClipboardItem item;
    item.id = NewUuidString();
    item.text = text;
    item.sourceApplicationName = source;
    item.createdAt = now;
    item.updatedAt = now;
    items_.insert(items_.begin(), std::move(item));
    PruneHistory(now);
    Save();
    Changed();
}

bool ClipboardStore::AddDib(const std::vector<uint8_t>& dib, const std::wstring& source, double now) {
    if (dib.size() > kMaxImageBytes) {
        lastError_ = L"Image too large (max 50MB)";
        Changed();
        return false;
    }
    if (DibPixelCount(dib) > kMaxImagePixels) {
        lastError_ = L"Image too large (max 16MP)";
        Changed();
        return false;
    }

    UINT width = 0, height = 0;
    auto png = imaging::DibToPng(dib.data(), dib.size(), width, height);
    if (!png) {
        lastError_ = L"Could not read the copied image.";
        Changed();
        return false;
    }
    return AddImage(*png, imaging::Sha256Hex(dib.data(), dib.size()), source, now);
}

bool ClipboardStore::AddImage(const std::vector<uint8_t>& encoded, const std::wstring& fingerprint,
                              const std::wstring& source, double now) {
    if (encoded.empty()) return false;
    if (encoded.size() > kMaxImageBytes) {
        lastError_ = L"Image too large (max 50MB)";
        Changed();
        return false;
    }

    UINT width = 0, height = 0;
    if (!imaging::ImageSize(encoded.data(), encoded.size(), width, height)) {
        lastError_ = L"Could not read image dimensions.";
        Changed();
        return false;
    }
    if (static_cast<uint64_t>(std::max<UINT>(width, 1)) * std::max<UINT>(height, 1) > kMaxImagePixels) {
        lastError_ = L"Image too large (max 16MP)";
        Changed();
        return false;
    }

    std::wstring id = NewUuidString();
    // Retry once for a transient I/O failure.
    std::wstring fileName = StoreImageFile(encoded, id);
    if (fileName.empty()) fileName = StoreImageFile(encoded, id);
    if (fileName.empty()) {
        lastError_ = L"Failed to store clipboard image to disk.";
        Changed();
        return false;
    }

    // Only dedupe once the write succeeded, or a failed write would lose the original.
    RemoveImageItemsMatching(fingerprint, &encoded);

    ClipboardItem item;
    item.id = id;
    item.text = L"Image";
    item.imageFileName = fileName;
    item.imageFingerprint = fingerprint;
    item.sourceApplicationName = source;
    item.createdAt = now;
    item.updatedAt = now;
    items_.insert(items_.begin(), std::move(item));
    PruneHistory(now);
    Save();
    Changed();
    return true;
}

void ClipboardStore::Delete(const std::wstring& id) {
    auto found = std::find_if(items_.begin(), items_.end(), [&](const ClipboardItem& item) { return item.id == id; });
    if (found == items_.end()) return;

    ClipboardItem item = *found;
    ClearClipboardIfCurrentItem(item);
    items_.erase(found);
    DeleteImageFile(item);
    Save();
    Changed();
}

std::wstring ClipboardStore::ImagePath(const ClipboardItem& item) const {
    if (item.imageFileName.empty() || imageDirectory_.empty()) return {};
    return imageDirectory_ + L"\\" + item.imageFileName;
}

std::optional<std::vector<uint8_t>> ClipboardStore::ImageBytes(const ClipboardItem& item) const {
    std::wstring path = ImagePath(item);
    if (path.empty()) return std::nullopt;
    return ReadFileBytes(path);
}

bool ClipboardStore::CopyToClipboard(const std::wstring& id) {
    const ClipboardItem* item = Find(id);
    if (!item) return false;

    if (item->IsImage()) {
        auto bytes = ImageBytes(*item);
        return bytes && SetClipboardImage(*bytes);
    }
    if (IsBlank(item->text)) return false;
    return SetClipboardText(item->text);
}

void ClipboardStore::Promote(const std::wstring& id) {
    auto found = std::find_if(items_.begin(), items_.end(), [&](const ClipboardItem& item) { return item.id == id; });
    if (found == items_.end()) return;

    ClipboardItem promoted = *found;
    items_.erase(found);
    double now = UnixNow();

    if (promoted.IsImage()) {
        promoted.updatedAt = now;
        if (!promoted.imageFingerprint.empty()) RemoveImageItemsMatching(promoted.imageFingerprint, nullptr);
        items_.insert(items_.begin(), std::move(promoted));
    } else if (!IsBlank(promoted.text)) {
        promoted.createdAt = now;
        promoted.updatedAt = now;
        items_.erase(std::remove_if(items_.begin(), items_.end(),
                                    [&](const ClipboardItem& item) {
                                        return !item.IsImage() && item.text == promoted.text;
                                    }),
                     items_.end());
        items_.insert(items_.begin(), std::move(promoted));
    }
    Save();
    Changed();
}

bool ClipboardStore::SetClipboardText(const std::wstring& text) {
    if (!OpenClipboardWithRetry(window_)) return false;
    EmptyClipboard();
    bool ok = SetGlobalData(CF_UNICODETEXT, text.c_str(), (text.size() + 1) * sizeof(wchar_t));
    CloseClipboard();
    lastSequence_ = GetClipboardSequenceNumber();
    return ok;
}

bool ClipboardStore::SetClipboardImage(const std::vector<uint8_t>& encoded) {
    auto bitmap = imaging::DecodeMemory(encoded.data(), encoded.size());
    if (!OpenClipboardWithRetry(window_)) return false;
    EmptyClipboard();

    // The encoded data as it is, for apps that read PNG or JPEG, and a DIB for the many
    // that only read bitmaps.
    UINT encodedFormat = imaging::DetectFormat(encoded.data(), encoded.size()) == imaging::EncodedFormat::Jpeg
        ? jfifFormat_
        : pngFormat_;
    bool ok = SetGlobalData(encodedFormat, encoded.data(), encoded.size());
    if (bitmap) {
        auto dib = imaging::MakeDib(*bitmap);
        ok = SetGlobalData(CF_DIB, dib.data(), dib.size()) || ok;
    }
    CloseClipboard();
    lastSequence_ = GetClipboardSequenceNumber();
    return ok;
}

void ClipboardStore::PruneHistory(double now) {
    double cutoff = now - retentionSeconds_;
    std::vector<ClipboardItem> retained;
    std::vector<ClipboardItem> removed;
    for (const auto& item : items_) {
        if (item.createdAt >= cutoff && retained.size() < maxItemCount_) {
            retained.push_back(item);
        } else {
            removed.push_back(item);
        }
    }
    if (removed.empty()) return;

    items_ = std::move(retained);
    for (const auto& item : removed) DeleteImageFile(item);
    Save();
    Changed();
}

std::wstring ClipboardStore::StoreImageFile(const std::vector<uint8_t>& encoded, const std::wstring& id) {
    if (imageDirectory_.empty() || !EnsureDirectory(imageDirectory_)) {
        lastError_ = L"Failed to store clipboard image: the image folder is unavailable.";
        return {};
    }
    const wchar_t* extension =
        imaging::DetectFormat(encoded.data(), encoded.size()) == imaging::EncodedFormat::Jpeg ? L".jpg" : L".png";
    std::wstring fileName = id + extension;
    if (!WriteFileAtomic(imageDirectory_ + L"\\" + fileName, encoded.data(), encoded.size())) {
        lastError_ = L"Failed to store clipboard image: " + HResultMessage(HRESULT_FROM_WIN32(GetLastError()));
        return {};
    }
    return fileName;
}

void ClipboardStore::RemoveImageItemsMatching(const std::wstring& fingerprint, const std::vector<uint8_t>* bytes) {
    std::vector<ClipboardItem> duplicates;
    for (const auto& item : items_) {
        if (!item.IsImage()) continue;
        if (!item.imageFingerprint.empty()) {
            if (item.imageFingerprint == fingerprint) duplicates.push_back(item);
        } else if (bytes) {
            auto stored = ImageBytes(item);
            if (stored && *stored == *bytes) duplicates.push_back(item);
        }
    }
    if (duplicates.empty()) return;

    std::unordered_set<std::wstring> ids;
    for (const auto& item : duplicates) ids.insert(item.id);
    items_.erase(std::remove_if(items_.begin(), items_.end(),
                                [&](const ClipboardItem& item) { return ids.count(item.id) > 0; }),
                 items_.end());
    for (const auto& item : duplicates) DeleteImageFile(item);
}

void ClipboardStore::DeleteImageFile(const ClipboardItem& item) {
    std::wstring path = ImagePath(item);
    if (!path.empty()) DeleteFileW(path.c_str());
}

void ClipboardStore::ClearClipboardIfCurrentItem(const ClipboardItem& item) {
    if (!OpenClipboardWithRetry(window_)) return;

    bool matches = false;
    if (item.IsImage()) {
        auto image = EncodedImageOnOpenClipboard();
        if (image) {
            if (!item.imageFingerprint.empty() &&
                imaging::Sha256Hex(image->bytes.data(), image->bytes.size()) == item.imageFingerprint) {
                matches = true;
            } else if (!image->isDib) {
                auto stored = ImageBytes(item);
                matches = stored && *stored == image->bytes;
            }
        }
    } else {
        auto text = ClipboardText();
        matches = text && *text == item.text;
    }

    if (matches) EmptyClipboard();
    CloseClipboard();
    if (matches) lastSequence_ = GetClipboardSequenceNumber();
}

void ClipboardStore::Load() {
    if (storagePath_.empty() || !FileExists(storagePath_)) return;

    auto bytes = ReadFileBytes(storagePath_);
    auto parsed = bytes ? json::Parse(std::string_view(reinterpret_cast<const char*>(bytes->data()), bytes->size()))
                        : std::nullopt;
    if (!parsed || !parsed->IsArray()) {
        // Nothing readable at all. Keep the file rather than letting the next save
        // overwrite it.
        PreserveUnreadableHistory(L"the file is not valid history");
        items_.clear();
        return;
    }

    size_t unreadable = 0;
    auto string = [](const json::Value& object, const char* key) {
        const json::Value* value = object.Find(key);
        return value && value->IsString() ? Utf8ToWide(value->AsString()) : std::wstring();
    };
    for (size_t i = 0; i < parsed->Size(); ++i) {
        const json::Value& record = parsed->At(i);
        const json::Value* createdAt = record.Find("createdAt");
        ClipboardItem item;
        item.id = string(record, "id");
        item.text = string(record, "text");
        if (!record.IsObject() || item.id.empty() || !createdAt || !createdAt->IsNumber()) {
            ++unreadable;
            continue;
        }
        item.imageFileName = string(record, "imageFileName");
        item.imageFingerprint = string(record, "imageFingerprint");
        item.sourceApplicationName = string(record, "sourceApplicationName");
        item.createdAt = createdAt->AsNumber();
        const json::Value* updatedAt = record.Find("updatedAt");
        item.updatedAt = updatedAt && updatedAt->IsNumber() ? updatedAt->AsNumber() : item.createdAt;
        items_.push_back(std::move(item));
    }

    if (unreadable > 0) {
        PreserveUnreadableHistory(FormatString(L"%zu %ls could not be read", unreadable,
                                               unreadable == 1 ? L"entry" : L"entries"));
    }
    std::stable_sort(items_.begin(), items_.end(),
                     [](const ClipboardItem& a, const ClipboardItem& b) { return a.createdAt > b.createdAt; });
}

// Copies the history file aside before anything can overwrite it, so a format change or
// a damaged record costs a notice instead of every entry.
void ClipboardStore::PreserveUnreadableHistory(const std::wstring& reason) {
    std::wstring base = storagePath_.substr(0, storagePath_.size() - std::wstring(L".json").size());
    std::wstring backup = base + FormatString(L".unreadable-%lld.json", static_cast<long long>(UnixNow()));
    CopyFileW(storagePath_.c_str(), backup.c_str(), TRUE);
    lastError_ = L"Some clipboard history could not be read (" + reason + L"). The original file was kept as " +
                 LastPathComponent(backup) + L".";
}

void ClipboardStore::Save() {
    if (storagePath_.empty()) return;

    json::Value array = json::Value::Array();
    for (const auto& item : items_) {
        json::Value record = json::Value::Object();
        record.Set("id", json::Value::String(WideToUtf8(item.id)));
        record.Set("text", json::Value::String(WideToUtf8(item.text)));
        if (!item.imageFileName.empty()) record.Set("imageFileName", json::Value::String(WideToUtf8(item.imageFileName)));
        if (!item.imageFingerprint.empty()) {
            record.Set("imageFingerprint", json::Value::String(WideToUtf8(item.imageFingerprint)));
        }
        if (!item.sourceApplicationName.empty()) {
            record.Set("sourceApplicationName", json::Value::String(WideToUtf8(item.sourceApplicationName)));
        }
        record.Set("createdAt", json::Value::Number(item.createdAt));
        record.Set("updatedAt", json::Value::Number(item.updatedAt));
        array.Append(std::move(record));
    }

    std::string text = json::Serialize(array);
    if (!WriteFileAtomic(storagePath_, text.data(), text.size())) {
        lastError_ = L"Failed to save clipboard history: " + HResultMessage(HRESULT_FROM_WIN32(GetLastError()));
    }
}

void ClipboardStore::Changed() {
    if (onChange) onChange();
}

}  // namespace space
