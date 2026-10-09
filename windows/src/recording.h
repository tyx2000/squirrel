// Purpose: Screen and window recording to MP4: a target picker, Windows.Graphics.Capture
// frames encoded to H.264 with Media Foundation, and optional system audio from WASAPI
// loopback encoded to AAC.

#pragma once

#include "common.h"

#include <memory>

namespace space {

enum class RecordingEvent : WPARAM { Started = 1, Finished = 2, Failed = 3 };

struct RecordingTarget {
    std::wstring title;
    bool isWindow = false;
    HMONITOR monitor = nullptr;
    HWND window = nullptr;
};

class Recorder;

class RecordingService {
public:
    explicit RecordingService(std::function<bool()> hidePanel);
    ~RecordingService();

    // The window that receives WM_APP_RECORDING_EVENT from the recording thread.
    void Attach(HWND messageWindow);

    void Toggle(std::function<void(const std::wstring&)> onFailure);
    void StopActive();
    // Stops and finalizes a recording in progress, waiting for the file to be written.
    void Shutdown();
    void HandleEvent(WPARAM event, LPARAM payload);

    bool IsRecording() const { return isRecording_; }
    ULONGLONG RecordingStartedAt() const { return startedAt_; }
    HMONITOR TargetMonitor() const;
    const std::wstring& LastMessage() const { return lastMessage_; }
    const std::wstring& OutputPath() const { return outputPath_; }
    void ClearMessage();

    std::function<void()> onChange;
    // Called around the modal target picker so the app can keep other UI out of its way.
    std::function<void(bool)> onModal;

private:
    void Start(std::function<void(const std::wstring&)> onFailure);
    std::optional<std::pair<RecordingTarget, bool>> PresentRecordingRequest(const std::vector<RecordingTarget>& options);
    void Fail(const std::wstring& message, const std::function<void(const std::wstring&)>& onFailure);
    void SetRecording(bool recording);
    void Changed();

    std::function<bool()> hidePanel_;
    HWND messageWindow_ = nullptr;
    std::unique_ptr<Recorder> recorder_;
    RecordingTarget target_;
    bool isPreparing_ = false;
    bool isRecording_ = false;
    ULONGLONG startedAt_ = 0;
    std::wstring lastMessage_;
    std::wstring outputPath_;
};

std::vector<RecordingTarget> RecordableTargets();

}  // namespace space
