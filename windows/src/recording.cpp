// Purpose: Implements the recording target picker and the capture/encode thread.

#include "recording.h"

#include "media_foundation.h"
#include "resource.h"
#include "window_manager.h"

#include <audioclient.h>
#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <mmdeviceapi.h>
#include <roapi.h>
#ifdef __MINGW32__
// MinGW's windows.foundation.h specializes IReference for both BYTE and boolean, which
// are the same type in C++; skip the second, which nothing here uses.
#define ____FIReference_1_boolean_INTERFACE_DEFINED__
#endif
#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.h>
#include <winstring.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <thread>

// Declared by the Windows SDK in windows.graphics.directx.direct3d11.interop.h, which
// MinGW does not ship.
MIDL_INTERFACE("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1")
IDirect3DDxgiInterfaceAccess : public IUnknown {
public:
    virtual HRESULT STDMETHODCALLTYPE GetInterface(REFIID iid, void** object) = 0;
};
#ifdef __CRT_UUID_DECL
__CRT_UUID_DECL(IDirect3DDxgiInterfaceAccess, 0xa9b3d012, 0x3df2, 0x4ee3, 0xb8, 0xd1, 0x86, 0x95, 0xf4, 0x57, 0xd3, 0xc1)
#endif
extern "C" HRESULT WINAPI CreateDirect3D11DeviceFromDXGIDevice(IDXGIDevice* dxgiDevice, IInspectable** graphicsDevice);

namespace space {

namespace WGC = ABI::Windows::Graphics::Capture;
namespace WGD3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using ABI::Windows::Graphics::SizeInt32;

namespace {

constexpr LONGLONG kHundredNanosecondsPerSecond = 10'000'000;
constexpr UINT32 kFramesPerSecond = 30;
constexpr LONGLONG kFrameInterval = kHundredNanosecondsPerSecond / kFramesPerSecond;
// The largest frame the Media Foundation H.264 encoder takes.
constexpr UINT32 kMaxEncodeWidth = 4096;
constexpr UINT32 kMaxEncodeHeight = 2304;
constexpr UINT32 kH264ProfileMain = 77;
constexpr DWORD kAacBytesPerSecond = 24000;  // 192 kbit/s

// {00000003-0000-0010-8000-00aa00389b71} and {00000001-...}: float and integer PCM.
constexpr GUID kSubtypeIeeeFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
constexpr GUID kSubtypePcm = {0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

class HString {
public:
    explicit HString(const wchar_t* text) {
        WindowsCreateString(text, static_cast<UINT32>(wcslen(text)), &value_);
    }
    ~HString() {
        if (value_) WindowsDeleteString(value_);
    }
    HString(const HString&) = delete;
    HString& operator=(const HString&) = delete;
    HSTRING Get() const { return value_; }

private:
    HSTRING value_ = nullptr;
};

template <typename T>
HRESULT ActivationFactory(const wchar_t* className, ComPtr<T>& factory) {
    HString name(className);
    return RoGetActivationFactory(name.Get(), __uuidof(T), reinterpret_cast<void**>(factory.ReleaseAndGetAddressOf()));
}

void SetPacked(IMFAttributes* attributes, REFGUID key, UINT32 high, UINT32 low) {
    attributes->SetUINT64(key, (static_cast<UINT64>(high) << 32) | low);
}

LONGLONG QpcTo100ns(LONGLONG ticks, LONGLONG frequency) {
    return (ticks / frequency) * kHundredNanosecondsPerSecond +
           (ticks % frequency) * kHundredNanosecondsPerSecond / frequency;
}

// BT.709 limited range, the matrix the stream is tagged with.
inline void RgbToYuv(int r, int g, int b, uint8_t& y) {
    y = static_cast<uint8_t>(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
}

// Converts top-down BGRA into NV12, fitting the source inside the frame with its aspect
// ratio kept and black around it.
void ConvertToNv12(const uint8_t* source, UINT sourcePitch, UINT sourceWidth, UINT sourceHeight, uint8_t* target,
                   UINT width, UINT height, std::vector<int>& xMap, std::vector<int>& yMap) {
    double scale = std::min(static_cast<double>(width) / sourceWidth, static_cast<double>(height) / sourceHeight);
    UINT fittedWidth = std::min(width, std::max<UINT>(1, static_cast<UINT>(std::lround(sourceWidth * scale))));
    UINT fittedHeight = std::min(height, std::max<UINT>(1, static_cast<UINT>(std::lround(sourceHeight * scale))));
    UINT offsetX = (width - fittedWidth) / 2;
    UINT offsetY = (height - fittedHeight) / 2;

    xMap.resize(width);
    yMap.resize(height);
    for (UINT x = 0; x < width; ++x) {
        xMap[x] = (x < offsetX || x >= offsetX + fittedWidth)
            ? -1
            : static_cast<int>(std::min<UINT64>(sourceWidth - 1, static_cast<UINT64>(x - offsetX) * sourceWidth / fittedWidth));
    }
    for (UINT y = 0; y < height; ++y) {
        yMap[y] = (y < offsetY || y >= offsetY + fittedHeight)
            ? -1
            : static_cast<int>(std::min<UINT64>(sourceHeight - 1, static_cast<UINT64>(y - offsetY) * sourceHeight / fittedHeight));
    }

    static const uint8_t kBlack[4] = {0, 0, 0, 255};
    uint8_t* lumaPlane = target;
    uint8_t* chromaPlane = target + static_cast<size_t>(width) * height;
    for (UINT y = 0; y < height; y += 2) {
        const uint8_t* row0 = yMap[y] >= 0 ? source + static_cast<size_t>(yMap[y]) * sourcePitch : nullptr;
        const uint8_t* row1 = yMap[y + 1] >= 0 ? source + static_cast<size_t>(yMap[y + 1]) * sourcePitch : nullptr;
        uint8_t* luma0 = lumaPlane + static_cast<size_t>(y) * width;
        uint8_t* luma1 = luma0 + width;
        uint8_t* chroma = chromaPlane + static_cast<size_t>(y / 2) * width;

        for (UINT x = 0; x < width; x += 2) {
            int sx0 = xMap[x], sx1 = xMap[x + 1];
            const uint8_t* p00 = (row0 && sx0 >= 0) ? row0 + sx0 * 4 : kBlack;
            const uint8_t* p01 = (row0 && sx1 >= 0) ? row0 + sx1 * 4 : kBlack;
            const uint8_t* p10 = (row1 && sx0 >= 0) ? row1 + sx0 * 4 : kBlack;
            const uint8_t* p11 = (row1 && sx1 >= 0) ? row1 + sx1 * 4 : kBlack;

            RgbToYuv(p00[2], p00[1], p00[0], luma0[x]);
            RgbToYuv(p01[2], p01[1], p01[0], luma0[x + 1]);
            RgbToYuv(p10[2], p10[1], p10[0], luma1[x]);
            RgbToYuv(p11[2], p11[1], p11[0], luma1[x + 1]);

            int r = (p00[2] + p01[2] + p10[2] + p11[2] + 2) >> 2;
            int g = (p00[1] + p01[1] + p10[1] + p11[1] + 2) >> 2;
            int b = (p00[0] + p01[0] + p10[0] + p11[0] + 2) >> 2;
            chroma[x] = static_cast<uint8_t>(((-26 * r - 86 * g + 112 * b + 128) >> 8) + 128);
            chroma[x + 1] = static_cast<uint8_t>(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128);
        }
    }
}

void PostRecordingEvent(HWND window, RecordingEvent event, std::wstring message) {
    auto* payload = new std::wstring(std::move(message));
    if (!window || !PostMessageW(window, WM_APP_RECORDING_EVENT, static_cast<WPARAM>(event),
                                 reinterpret_cast<LPARAM>(payload))) {
        delete payload;
    }
}

// System audio through WASAPI loopback on the default output device, delivered as 16-bit
// stereo PCM at 44.1 or 48 kHz, the rates the AAC encoder takes.
class LoopbackAudio {
public:
    ~LoopbackAudio() {
        if (client_) client_->Stop();
        CoTaskMemFree(format_);
    }

    HRESULT Start(std::wstring& error) {
        ComPtr<IMMDeviceEnumerator> enumerator;
        ComPtr<IMMDevice> device;
        HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
        if (SUCCEEDED(hr)) hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
        if (SUCCEEDED(hr)) {
            hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  reinterpret_cast<void**>(client_.GetAddressOf()));
        }
        if (SUCCEEDED(hr)) hr = client_->GetMixFormat(&format_);
        if (FAILED(hr)) {
            error = L"no audio output device is available";
            return hr;
        }

        channels_ = format_->nChannels;
        bytesPerSample_ = format_->wBitsPerSample / 8;
        bool isFloat = format_->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
        bool isPcm = format_->wFormatTag == WAVE_FORMAT_PCM;
        if (format_->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format_->cbSize >= 22) {
            const auto* extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format_);
            isFloat = IsEqualGUID(extensible->SubFormat, kSubtypeIeeeFloat);
            isPcm = IsEqualGUID(extensible->SubFormat, kSubtypePcm);
        }
        isFloat_ = isFloat && bytesPerSample_ == 4;
        if (!isFloat_ && !(isPcm && (bytesPerSample_ == 2 || bytesPerSample_ == 3 || bytesPerSample_ == 4))) {
            error = L"the output device's audio format is not supported";
            return E_NOTIMPL;
        }

        // Rates above 48 kHz are taken down by an integer factor.
        UINT32 inputRate = format_->nSamplesPerSec;
        for (UINT32 factor : {1u, 2u, 4u}) {
            if (inputRate % factor == 0 && (inputRate / factor == 48000 || inputRate / factor == 44100)) {
                decimation_ = factor;
                outputRate_ = inputRate / factor;
                break;
            }
        }
        if (outputRate_ == 0) {
            error = FormatString(L"the output device runs at %u Hz", inputRate);
            return E_NOTIMPL;
        }

        hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, kHundredNanosecondsPerSecond,
                                 0, format_, nullptr);
        if (SUCCEEDED(hr)) {
            hr = client_->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(capture_.GetAddressOf()));
        }
        if (SUCCEEDED(hr)) hr = client_->Start();
        if (FAILED(hr)) error = L"the output device could not be opened (" + HResultMessage(hr) + L")";
        return hr;
    }

    UINT32 OutputRate() const { return outputRate_; }

    // Calls `deliver` with each packet's start time (100ns QPC units) and its samples.
    template <typename Deliver>
    HRESULT Drain(Deliver&& deliver) {
        UINT32 packetFrames = 0;
        HRESULT hr = S_OK;
        while (SUCCEEDED(hr = capture_->GetNextPacketSize(&packetFrames)) && packetFrames > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            UINT64 devicePosition = 0, qpcPosition = 0;
            hr = capture_->GetBuffer(&data, &frames, &flags, &devicePosition, &qpcPosition);
            if (FAILED(hr)) return hr;

            converted_.clear();
            bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
            UINT32 blockAlign = format_->nBlockAlign;
            for (UINT32 frame = 0; frame < frames; ++frame) {
                if (phase_++ % decimation_ != 0) continue;
                const BYTE* sample = data + static_cast<size_t>(frame) * blockAlign;
                converted_.push_back(silent ? 0 : ReadSample(sample, 0));
                converted_.push_back(silent ? 0 : ReadSample(sample, channels_ > 1 ? 1 : 0));
            }
            phase_ %= decimation_;
            capture_->ReleaseBuffer(frames);
            if (!converted_.empty()) deliver(static_cast<LONGLONG>(qpcPosition), converted_);
        }
        return hr;
    }

private:
    int16_t ReadSample(const BYTE* frame, UINT32 channel) const {
        const BYTE* sample = frame + static_cast<size_t>(channel) * bytesPerSample_;
        if (isFloat_) {
            float value;
            std::memcpy(&value, sample, sizeof(value));
            value = std::max(-1.0f, std::min(1.0f, value));
            return static_cast<int16_t>(std::lround(value * 32767.0f));
        }
        switch (bytesPerSample_) {
            case 2: {
                int16_t value;
                std::memcpy(&value, sample, sizeof(value));
                return value;
            }
            case 3:
                return static_cast<int16_t>(sample[1] | (sample[2] << 8));
            default: {
                int32_t value;
                std::memcpy(&value, sample, sizeof(value));
                return static_cast<int16_t>(value >> 16);
            }
        }
    }

    ComPtr<IAudioClient> client_;
    ComPtr<IAudioCaptureClient> capture_;
    WAVEFORMATEX* format_ = nullptr;
    UINT32 channels_ = 2;
    UINT32 bytesPerSample_ = 4;
    bool isFloat_ = true;
    UINT32 decimation_ = 1;
    UINT32 outputRate_ = 0;
    UINT64 phase_ = 0;
    std::vector<int16_t> converted_;
};

}  // namespace

class Recorder {
public:
    Recorder(RecordingTarget target, bool recordsAudio, std::wstring outputPath, HWND notifyWindow)
        : target_(std::move(target)),
          recordsAudio_(recordsAudio),
          outputPath_(std::move(outputPath)),
          notifyWindow_(notifyWindow),
          stopEvent_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

    ~Recorder() {
        RequestStop();
        Join();
        if (stopEvent_) CloseHandle(stopEvent_);
    }

    void Start() {
        thread_ = std::thread([this] { Run(); });
    }

    void RequestStop() {
        stopRequested_ = true;
        if (stopEvent_) SetEvent(stopEvent_);
    }

    void Join() {
        if (thread_.joinable()) thread_.join();
    }

private:
    void Run() {
        HRESULT init = RoInitialize(RO_INIT_MULTITHREADED);
        std::wstring error;
        HRESULT hr = Record(error);
        Release();
        if (SUCCEEDED(hr)) {
            PostRecordingEvent(notifyWindow_, RecordingEvent::Finished, notice_);
        } else {
            if (!startedWriting_) DeleteFileW(outputPath_.c_str());
            if (error.empty()) error = HResultMessage(hr);
            PostRecordingEvent(notifyWindow_, RecordingEvent::Failed, error);
        }
        if (SUCCEEDED(init)) RoUninitialize();
    }

    void Release() {
        writer_.Reset();
        audio_.reset();
    }

    LONGLONG Now() const {
        LARGE_INTEGER now{};
        QueryPerformanceCounter(&now);
        return QpcTo100ns(now.QuadPart - startTicks_, frequency_);
    }

    HRESULT Record(std::wstring& error) {
        if (!mf::IsAvailable()) {
            error = L"Screen recording needs Media Foundation. On Windows N editions, add the Media Feature Pack "
                    L"in Settings > Apps > Optional features.";
            return E_NOTIMPL;
        }

        ComPtr<WGC::IGraphicsCaptureSessionStatics> sessionStatics;
        boolean supported = false;
        if (FAILED(ActivationFactory(L"Windows.Graphics.Capture.GraphicsCaptureSession", sessionStatics)) ||
            FAILED(sessionStatics->IsSupported(&supported)) || !supported) {
            error = L"Screen recording requires Windows 10 version 1903 or later.";
            return E_NOTIMPL;
        }

        // Direct3D device that the capture frames live on.
        ComPtr<ID3D11Device> d3dDevice;
        ComPtr<ID3D11DeviceContext> context;
        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                       nullptr, 0, D3D11_SDK_VERSION, &d3dDevice, nullptr, &context);
        if (FAILED(hr)) {
            hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                   D3D11_SDK_VERSION, &d3dDevice, nullptr, &context);
        }
        if (FAILED(hr)) {
            error = L"Direct3D is unavailable (" + HResultMessage(hr) + L").";
            return hr;
        }
        ComPtr<IDXGIDevice> dxgiDevice;
        ComPtr<IInspectable> inspectableDevice;
        ComPtr<WGD3D::IDirect3DDevice> device;
        SPACE_RETURN_IF_FAILED(d3dDevice.As(&dxgiDevice));
        SPACE_RETURN_IF_FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.Get(), &inspectableDevice));
        SPACE_RETURN_IF_FAILED(inspectableDevice.As(&device));

        // What to record.
        ComPtr<IGraphicsCaptureItemInterop> interop;
        ComPtr<WGC::IGraphicsCaptureItem> item;
        SPACE_RETURN_IF_FAILED(ActivationFactory(L"Windows.Graphics.Capture.GraphicsCaptureItem", interop));
        hr = target_.isWindow
            ? interop->CreateForWindow(target_.window, __uuidof(WGC::IGraphicsCaptureItem),
                                       reinterpret_cast<void**>(item.GetAddressOf()))
            : interop->CreateForMonitor(target_.monitor, __uuidof(WGC::IGraphicsCaptureItem),
                                        reinterpret_cast<void**>(item.GetAddressOf()));
        if (FAILED(hr)) {
            error = target_.isWindow ? L"That window can no longer be recorded." : L"That screen can no longer be recorded.";
            return hr;
        }
        SizeInt32 itemSize{};
        SPACE_RETURN_IF_FAILED(item->get_Size(&itemSize));
        if (itemSize.Width <= 0 || itemSize.Height <= 0) {
            error = L"The selected window has no visible area.";
            return E_FAIL;
        }

        ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> poolStatics;
        ComPtr<WGC::IDirect3D11CaptureFramePool> pool;
        ComPtr<WGC::IGraphicsCaptureSession> session;
        SPACE_RETURN_IF_FAILED(ActivationFactory(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool", poolStatics));
        SPACE_RETURN_IF_FAILED(poolStatics->CreateFreeThreaded(
            device.Get(), ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2, itemSize, &pool));
        SPACE_RETURN_IF_FAILED(pool->CreateCaptureSession(item.Get(), &session));
        ComPtr<WGC::IGraphicsCaptureSession2> session2;
        if (SUCCEEDED(session.As(&session2))) session2->put_IsCursorCaptureEnabled(true);
        // Windows 11 lets an app drop the yellow capture border; older systems keep it.
        ComPtr<WGC::IGraphicsCaptureSession3> session3;
        if (SUCCEEDED(session.As(&session3))) session3->put_IsBorderRequired(false);

        // The encoded frame: the item's size, even, within the encoder's limits.
        double fit = std::min({1.0, static_cast<double>(kMaxEncodeWidth) / itemSize.Width,
                               static_cast<double>(kMaxEncodeHeight) / itemSize.Height});
        width_ = std::max<UINT32>(2, static_cast<UINT32>(itemSize.Width * fit) & ~1u);
        height_ = std::max<UINT32>(2, static_cast<UINT32>(itemSize.Height * fit) & ~1u);

        hr = CreateWriter(error);
        if (FAILED(hr)) return hr;

        SPACE_RETURN_IF_FAILED(writer_->BeginWriting());
        startedWriting_ = true;
        hr = session->StartCapture();
        if (FAILED(hr)) {
            error = L"Capture could not start (" + HResultMessage(hr) + L").";
            writer_->Finalize();
            return hr;
        }

        LARGE_INTEGER frequency{}, start{};
        QueryPerformanceFrequency(&frequency);
        QueryPerformanceCounter(&start);
        frequency_ = frequency.QuadPart;
        startTicks_ = start.QuadPart;
        start100ns_ = QpcTo100ns(startTicks_, frequency_);

        PostRecordingEvent(notifyWindow_, RecordingEvent::Started, notice_);

        hr = CaptureLoop(d3dDevice.Get(), context.Get(), device.Get(), pool.Get(), itemSize, error);

        ComPtr<ABI::Windows::Foundation::IClosable> closable;
        if (SUCCEEDED(session.As(&closable))) closable->Close();
        if (SUCCEEDED(pool.As(&closable))) closable->Close();

        HRESULT finalized = writer_->Finalize();
        if (FAILED(hr)) return hr;
        if (FAILED(finalized)) {
            error = L"The recording could not be finalized (" + HResultMessage(finalized) + L").";
            return finalized;
        }
        return S_OK;
    }

    HRESULT CreateWriter(std::wstring& error) {
        ComPtr<IMFAttributes> attributes;
        SPACE_RETURN_IF_FAILED(mf::CreateAttributes(&attributes, 2));
        attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
        attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
        HRESULT hr = mf::CreateSinkWriterFromURL(outputPath_.c_str(), nullptr, attributes.Get(), &writer_);
        if (FAILED(hr)) {
            error = L"The file could not be created in Downloads (" + HResultMessage(hr) + L").";
            return hr;
        }

        UINT32 bitrate = static_cast<UINT32>(std::min(40'000'000.0, std::max(3'000'000.0,
            static_cast<double>(width_) * height_ * kFramesPerSecond * 0.12)));

        ComPtr<IMFMediaType> videoOut, videoIn;
        SPACE_RETURN_IF_FAILED(mf::CreateMediaType(&videoOut));
        videoOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        videoOut->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        videoOut->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
        videoOut->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        videoOut->SetUINT32(MF_MT_MPEG2_PROFILE, kH264ProfileMain);
        SetPacked(videoOut.Get(), MF_MT_FRAME_SIZE, width_, height_);
        SetPacked(videoOut.Get(), MF_MT_FRAME_RATE, kFramesPerSecond, 1);
        SetPacked(videoOut.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        hr = writer_->AddStream(videoOut.Get(), &videoStream_);
        if (FAILED(hr)) {
            error = FormatString(L"The H.264 encoder rejected a %ux%u frame (%ls).", width_, height_,
                                 HResultMessage(hr).c_str());
            return hr;
        }

        SPACE_RETURN_IF_FAILED(mf::CreateMediaType(&videoIn));
        videoIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        videoIn->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        videoIn->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        videoIn->SetUINT32(MF_MT_DEFAULT_STRIDE, width_);
        videoIn->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
        videoIn->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
        SetPacked(videoIn.Get(), MF_MT_FRAME_SIZE, width_, height_);
        SetPacked(videoIn.Get(), MF_MT_FRAME_RATE, kFramesPerSecond, 1);
        SetPacked(videoIn.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        hr = writer_->SetInputMediaType(videoStream_, videoIn.Get(), nullptr);
        if (FAILED(hr)) {
            error = L"The H.264 encoder is unavailable (" + HResultMessage(hr) + L").";
            return hr;
        }

        if (recordsAudio_) {
            std::wstring audioError;
            auto audio = std::make_unique<LoopbackAudio>();
            if (SUCCEEDED(audio->Start(audioError)) && SUCCEEDED(AddAudioStream(audio->OutputRate()))) {
                audio_ = std::move(audio);
            } else {
                // The picture still records; say why the sound did not.
                notice_ = L"System audio is not being recorded: " +
                          (audioError.empty() ? std::wstring(L"the AAC encoder is unavailable") : audioError) + L".";
            }
        }
        return S_OK;
    }

    HRESULT AddAudioStream(UINT32 rate) {
        ComPtr<IMFMediaType> audioOut, audioIn;
        SPACE_RETURN_IF_FAILED(mf::CreateMediaType(&audioOut));
        audioOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        audioOut->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
        audioOut->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        audioOut->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
        audioOut->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        audioOut->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAacBytesPerSecond);
        SPACE_RETURN_IF_FAILED(writer_->AddStream(audioOut.Get(), &audioStream_));

        SPACE_RETURN_IF_FAILED(mf::CreateMediaType(&audioIn));
        audioIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        audioIn->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        audioIn->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        audioIn->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
        audioIn->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        audioIn->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
        audioIn->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * 4);
        return writer_->SetInputMediaType(audioStream_, audioIn.Get(), nullptr);
    }

    HRESULT CaptureLoop(ID3D11Device* d3dDevice, ID3D11DeviceContext* context, WGD3D::IDirect3DDevice* device,
                        WGC::IDirect3D11CaptureFramePool* pool, SizeInt32 poolSize, std::wstring& error) {
        ComPtr<ID3D11Texture2D> staging;
        D3D11_TEXTURE2D_DESC stagingDesc{};
        SizeInt32 contentSize{};
        bool frameWaiting = false;
        LONGLONG lastVideoTime = -1;
        HRESULT hr = S_OK;

        while (!stopRequested_) {
            // Take every frame that arrived and keep only the newest.
            for (;;) {
                ComPtr<WGC::IDirect3D11CaptureFrame> frame;
                if (FAILED(pool->TryGetNextFrame(&frame)) || !frame) break;

                SizeInt32 size{};
                ComPtr<WGD3D::IDirect3DSurface> surface;
                ComPtr<IDirect3DDxgiInterfaceAccess> access;
                ComPtr<ID3D11Texture2D> texture;
                frame->get_ContentSize(&size);
                if (SUCCEEDED(frame->get_Surface(&surface)) && SUCCEEDED(surface.As(&access)) &&
                    SUCCEEDED(access->GetInterface(__uuidof(ID3D11Texture2D),
                                                   reinterpret_cast<void**>(texture.GetAddressOf())))) {
                    D3D11_TEXTURE2D_DESC desc{};
                    texture->GetDesc(&desc);
                    if (!staging || desc.Width != stagingDesc.Width || desc.Height != stagingDesc.Height) {
                        stagingDesc = desc;
                        stagingDesc.Usage = D3D11_USAGE_STAGING;
                        stagingDesc.BindFlags = 0;
                        stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                        stagingDesc.MiscFlags = 0;
                        staging.Reset();
                        d3dDevice->CreateTexture2D(&stagingDesc, nullptr, &staging);
                    }
                    if (staging) {
                        context->CopyResource(staging.Get(), texture.Get());
                        contentSize.Width = std::min<INT32>(size.Width, static_cast<INT32>(desc.Width));
                        contentSize.Height = std::min<INT32>(size.Height, static_cast<INT32>(desc.Height));
                        frameWaiting = contentSize.Width > 0 && contentSize.Height > 0;
                    }
                }

                ComPtr<ABI::Windows::Foundation::IClosable> closable;
                if (SUCCEEDED(frame.As(&closable))) closable->Close();

                // A resized window delivers frames at its new size once the pool matches.
                if (size.Width > 0 && size.Height > 0 &&
                    (size.Width != poolSize.Width || size.Height != poolSize.Height)) {
                    pool->Recreate(device, ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized,
                                   2, size);
                    poolSize = size;
                }
            }

            LONGLONG now = Now();
            if (frameWaiting && (lastVideoTime < 0 || now - lastVideoTime >= kFrameInterval)) {
                LONGLONG time = std::max(now, lastVideoTime + 1);
                hr = WriteFrame(context, staging.Get(), contentSize, time);
                if (FAILED(hr)) {
                    error = L"A frame could not be encoded (" + HResultMessage(hr) + L").";
                    return hr;
                }
                lastVideoTime = time;
                frameWaiting = false;
            }

            if (audio_) {
                hr = DrainAudio(now);
                if (FAILED(hr)) {
                    // Output devices come and go; keep the picture.
                    audio_.reset();
                    notice_ = L"System audio stopped recording when the output device changed.";
                }
            }

            if (target_.isWindow && !IsWindow(target_.window)) {
                notice_ = L"The recorded window was closed.";
                break;
            }
            WaitForSingleObject(stopEvent_, 5);
        }

        // Hold the last picture to the moment recording stopped.
        LONGLONG end = Now();
        if (lastFrame_ && lastVideoTime >= 0) {
            hr = WriteBuffer(lastFrame_.Get(), std::max(end, lastVideoTime + 1));
            if (FAILED(hr)) return hr;
        }
        if (audio_) {
            DrainAudio(end);
            WriteSilenceUntil(end);
        }
        return S_OK;
    }

    HRESULT WriteFrame(ID3D11DeviceContext* context, ID3D11Texture2D* staging, SizeInt32 contentSize, LONGLONG time) {
        D3D11_MAPPED_SUBRESOURCE mapped{};
        SPACE_RETURN_IF_FAILED(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped));

        DWORD size = width_ * height_ * 3 / 2;
        ComPtr<IMFMediaBuffer> buffer;
        BYTE* data = nullptr;
        HRESULT hr = mf::CreateMemoryBuffer(size, &buffer);
        if (SUCCEEDED(hr)) hr = buffer->Lock(&data, nullptr, nullptr);
        if (SUCCEEDED(hr)) {
            ConvertToNv12(static_cast<const uint8_t*>(mapped.pData), mapped.RowPitch,
                          static_cast<UINT>(contentSize.Width), static_cast<UINT>(contentSize.Height), data, width_,
                          height_, xMap_, yMap_);
            buffer->Unlock();
            buffer->SetCurrentLength(size);
        }
        context->Unmap(staging, 0);
        if (FAILED(hr)) return hr;

        lastFrame_ = buffer;
        return WriteBuffer(buffer.Get(), time);
    }

    HRESULT WriteBuffer(IMFMediaBuffer* buffer, LONGLONG time) {
        ComPtr<IMFSample> sample;
        SPACE_RETURN_IF_FAILED(mf::CreateSample(&sample));
        SPACE_RETURN_IF_FAILED(sample->AddBuffer(buffer));
        sample->SetSampleTime(time);
        sample->SetSampleDuration(kFrameInterval);
        return writer_->WriteSample(videoStream_, sample.Get());
    }

    HRESULT DrainAudio(LONGLONG now) {
        HRESULT writeResult = S_OK;
        bool delivered = false;
        HRESULT hr = audio_->Drain([&](LONGLONG qpcPosition, const std::vector<int16_t>& samples) {
            delivered = true;
            // Loopback delivers nothing while nothing plays, so fill the gap with silence
            // to keep the sound in step with the picture.
            LONGLONG packetTime = qpcPosition - start100ns_;
            // Sound buffered before the picture started would put the audio ahead of it.
            if (packetTime < 0) return;
            if (packetTime > AudioTime() + kHundredNanosecondsPerSecond / 50) WriteSilenceUntil(packetTime);
            if (SUCCEEDED(writeResult)) writeResult = WriteAudio(samples.data(), static_cast<UINT32>(samples.size() / 2));
        });
        // During long silences, keep the audio track moving so the muxer does not hold
        // video back waiting for it.
        if (!delivered && now - AudioTime() > kHundredNanosecondsPerSecond * 3 / 10) {
            WriteSilenceUntil(now - kHundredNanosecondsPerSecond / 10);
        }
        return FAILED(hr) ? hr : writeResult;
    }

    LONGLONG AudioTime() const {
        return static_cast<LONGLONG>(audioFrames_ * kHundredNanosecondsPerSecond / audio_->OutputRate());
    }

    void WriteSilenceUntil(LONGLONG time) {
        UINT32 rate = audio_->OutputRate();
        if (time <= AudioTime()) return;
        UINT64 target = static_cast<UINT64>(time) * rate / kHundredNanosecondsPerSecond;
        std::vector<int16_t> silence;
        while (audioFrames_ < target) {
            UINT32 frames = static_cast<UINT32>(std::min<UINT64>(target - audioFrames_, rate / 10));
            silence.assign(static_cast<size_t>(frames) * 2, 0);
            if (FAILED(WriteAudio(silence.data(), frames))) return;
        }
    }

    HRESULT WriteAudio(const int16_t* samples, UINT32 frames) {
        if (frames == 0) return S_OK;
        UINT32 rate = audio_->OutputRate();
        DWORD bytes = frames * 4;
        ComPtr<IMFMediaBuffer> buffer;
        ComPtr<IMFSample> sample;
        BYTE* data = nullptr;
        SPACE_RETURN_IF_FAILED(mf::CreateMemoryBuffer(bytes, &buffer));
        SPACE_RETURN_IF_FAILED(buffer->Lock(&data, nullptr, nullptr));
        std::memcpy(data, samples, bytes);
        buffer->Unlock();
        buffer->SetCurrentLength(bytes);
        SPACE_RETURN_IF_FAILED(mf::CreateSample(&sample));
        SPACE_RETURN_IF_FAILED(sample->AddBuffer(buffer.Get()));
        sample->SetSampleTime(static_cast<LONGLONG>(audioFrames_ * kHundredNanosecondsPerSecond / rate));
        sample->SetSampleDuration(static_cast<LONGLONG>(static_cast<UINT64>(frames) * kHundredNanosecondsPerSecond / rate));
        audioFrames_ += frames;
        return writer_->WriteSample(audioStream_, sample.Get());
    }

    RecordingTarget target_;
    bool recordsAudio_;
    std::wstring outputPath_;
    HWND notifyWindow_;
    HANDLE stopEvent_;
    std::thread thread_;
    std::atomic<bool> stopRequested_{false};

    ComPtr<IMFSinkWriter> writer_;
    std::unique_ptr<LoopbackAudio> audio_;
    DWORD videoStream_ = 0;
    DWORD audioStream_ = 0;
    UINT32 width_ = 0;
    UINT32 height_ = 0;
    bool startedWriting_ = false;
    std::wstring notice_;

    LONGLONG frequency_ = 1;
    LONGLONG startTicks_ = 0;
    LONGLONG start100ns_ = 0;
    UINT64 audioFrames_ = 0;
    ComPtr<IMFMediaBuffer> lastFrame_;
    std::vector<int> xMap_;
    std::vector<int> yMap_;
};

namespace {

bool IsRecordableWindow(HWND hwnd) {
    if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || GetWindow(hwnd, GW_OWNER)) return false;
    if (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return false;

    DWORD processId = 0;
    GetWindowThreadProcessId(hwnd, &processId);
    if (processId == GetCurrentProcessId()) return false;

    DWORD cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked) return false;

    wchar_t className[64] = {};
    GetClassNameW(hwnd, className, 64);
    if (wcscmp(className, L"Progman") == 0 || wcscmp(className, L"Shell_TrayWnd") == 0 ||
        wcscmp(className, L"Shell_SecondaryTrayWnd") == 0) {
        return false;
    }

    RECT frame{};
    if (!VisibleFrame(hwnd, frame)) return false;
    return frame.right - frame.left >= 80 && frame.bottom - frame.top >= 60 && GetWindowTextLengthW(hwnd) > 0;
}

struct DialogState {
    const std::vector<RecordingTarget>* options = nullptr;
    int selected = 0;
    bool recordsAudio = false;
};

INT_PTR CALLBACK RecordDialogProc(HWND dialog, UINT message, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<DialogState*>(GetWindowLongPtrW(dialog, DWLP_USER));
    switch (message) {
        case WM_INITDIALOG: {
            SetWindowLongPtrW(dialog, DWLP_USER, lParam);
            state = reinterpret_cast<DialogState*>(lParam);
            HWND combo = GetDlgItem(dialog, IDC_RECORD_TARGET);
            for (const auto& option : *state->options) {
                SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(option.title.c_str()));
            }
            SendMessageW(combo, CB_SETCURSEL, 0, 0);
            CheckDlgButton(dialog, IDC_RECORD_AUDIO, BST_UNCHECKED);
            HICON icon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP));
            SendMessageW(dialog, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon));
            BringToForeground(dialog);
            return TRUE;
        }
        case WM_COMMAND:
            if (LOWORD(wParam) == IDOK) {
                state->selected = static_cast<int>(SendDlgItemMessageW(dialog, IDC_RECORD_TARGET, CB_GETCURSEL, 0, 0));
                state->recordsAudio = IsDlgButtonChecked(dialog, IDC_RECORD_AUDIO) == BST_CHECKED;
                EndDialog(dialog, IDOK);
                return TRUE;
            }
            if (LOWORD(wParam) == IDCANCEL) {
                EndDialog(dialog, IDCANCEL);
                return TRUE;
            }
            break;
        default:
            break;
    }
    return FALSE;
}

}  // namespace

std::vector<RecordingTarget> RecordableTargets() {
    std::vector<RecordingTarget> displays;
    EnumDisplayMonitors(
        nullptr, nullptr,
        [](HMONITOR monitor, HDC, LPRECT, LPARAM parameter) -> BOOL {
            auto* list = reinterpret_cast<std::vector<RecordingTarget>*>(parameter);
            MONITORINFO info{sizeof(info)};
            if (!GetMonitorInfoW(monitor, &info)) return TRUE;
            bool primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
            RecordingTarget target;
            target.monitor = monitor;
            target.title = FormatString(L"Full Screen%ls - %ldx%ld", primary ? L" (Main)" : L"",
                                        info.rcMonitor.right - info.rcMonitor.left,
                                        info.rcMonitor.bottom - info.rcMonitor.top);
            if (primary) list->insert(list->begin(), std::move(target));
            else list->push_back(std::move(target));
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&displays));

    std::vector<RecordingTarget> windows;
    EnumWindows(
        [](HWND hwnd, LPARAM parameter) -> BOOL {
            if (!IsRecordableWindow(hwnd)) return TRUE;
            auto* list = reinterpret_cast<std::vector<RecordingTarget>*>(parameter);
            int length = GetWindowTextLengthW(hwnd);
            std::wstring title(static_cast<size_t>(length) + 1, L'\0');
            title.resize(static_cast<size_t>(GetWindowTextW(hwnd, title.data(), length + 1)));
            RecordingTarget target;
            target.isWindow = true;
            target.window = hwnd;
            target.title = AppNameForWindow(hwnd) + L" - " + title;
            list->push_back(std::move(target));
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&windows));
    std::sort(windows.begin(), windows.end(), [](const RecordingTarget& a, const RecordingTarget& b) {
        return lstrcmpiW(a.title.c_str(), b.title.c_str()) < 0;
    });

    displays.insert(displays.end(), windows.begin(), windows.end());
    return displays;
}

RecordingService::RecordingService(std::function<bool()> hidePanel) : hidePanel_(std::move(hidePanel)) {}

RecordingService::~RecordingService() {
    Shutdown();
}

void RecordingService::Attach(HWND messageWindow) {
    messageWindow_ = messageWindow;
}

HMONITOR RecordingService::TargetMonitor() const {
    if (target_.isWindow && IsWindow(target_.window)) return MonitorFromWindow(target_.window, MONITOR_DEFAULTTONEAREST);
    return target_.monitor ? target_.monitor : MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
}

void RecordingService::ClearMessage() {
    lastMessage_.clear();
    Changed();
}

void RecordingService::Toggle(std::function<void(const std::wstring&)> onFailure) {
    if (recorder_) {
        StopActive();
        return;
    }
    if (isPreparing_) {
        Fail(L"Screen recording is still preparing.", onFailure);
        return;
    }
    Start(std::move(onFailure));
}

void RecordingService::Start(std::function<void(const std::wstring&)> onFailure) {
    hidePanel_();
    isPreparing_ = true;

    auto options = RecordableTargets();
    if (options.empty()) {
        isPreparing_ = false;
        Fail(L"Screen recording found no screens or windows to record.", onFailure);
        return;
    }

    auto request = PresentRecordingRequest(options);
    isPreparing_ = false;
    if (!request) return;

    target_ = request->first;
    outputPath_ = DownloadsDirectory() + L"\\Space-" + CompactTimestamp() + L".mp4";
    recorder_ = std::make_unique<Recorder>(target_, request->second, outputPath_, messageWindow_);
    recorder_->Start();
    Changed();
}

std::optional<std::pair<RecordingTarget, bool>> RecordingService::PresentRecordingRequest(
    const std::vector<RecordingTarget>& options) {
    DialogState state;
    state.options = &options;
    if (onModal) onModal(true);
    INT_PTR result = DialogBoxParamW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDD_RECORD), nullptr,
                                     &RecordDialogProc, reinterpret_cast<LPARAM>(&state));
    if (onModal) onModal(false);

    if (result != IDOK || state.selected < 0 || state.selected >= static_cast<int>(options.size())) {
        return std::nullopt;
    }
    return std::make_pair(options[static_cast<size_t>(state.selected)], state.recordsAudio);
}

void RecordingService::StopActive() {
    if (recorder_) recorder_->RequestStop();
}

void RecordingService::Shutdown() {
    if (!recorder_) return;
    recorder_->RequestStop();
    recorder_->Join();
    recorder_.reset();
    SetRecording(false);
}

void RecordingService::HandleEvent(WPARAM event, LPARAM payload) {
    std::unique_ptr<std::wstring> message(reinterpret_cast<std::wstring*>(payload));
    std::wstring detail = message ? *message : std::wstring();
    std::wstring fileName = LastPathComponent(outputPath_);

    switch (static_cast<RecordingEvent>(event)) {
        case RecordingEvent::Started:
            SetRecording(true);
            lastMessage_ = L"Recording started: " + fileName + (detail.empty() ? L"" : L" " + detail);
            break;
        case RecordingEvent::Finished:
            if (recorder_) recorder_->Join();
            recorder_.reset();
            SetRecording(false);
            lastMessage_ = L"Recording saved to Downloads: " + fileName + (detail.empty() ? L"" : L" " + detail);
            break;
        case RecordingEvent::Failed:
            if (recorder_) recorder_->Join();
            recorder_.reset();
            SetRecording(false);
            outputPath_.clear();
            lastMessage_ = L"Screen recording failed: " + detail;
            break;
    }
    Changed();
}

void RecordingService::Fail(const std::wstring& message, const std::function<void(const std::wstring&)>& onFailure) {
    lastMessage_ = message;
    Changed();
    if (onFailure) onFailure(message);
}

void RecordingService::SetRecording(bool recording) {
    if (recording == isRecording_) return;
    isRecording_ = recording;
    startedAt_ = recording ? GetTickCount64() : 0;
}

void RecordingService::Changed() {
    if (onChange) onChange();
}

}  // namespace space
