// Purpose: Implements the run-time binding to mfplat.dll and mfreadwrite.dll.

#include "media_foundation.h"

namespace space::mf {

namespace {

using StartupFn = HRESULT(WINAPI*)(ULONG, DWORD);
using ShutdownFn = HRESULT(WINAPI*)();
using CreateAttributesFn = HRESULT(WINAPI*)(IMFAttributes**, UINT32);
using CreateSinkWriterFn = HRESULT(WINAPI*)(LPCWSTR, IMFByteStream*, IMFAttributes*, IMFSinkWriter**);
using CreateMediaTypeFn = HRESULT(WINAPI*)(IMFMediaType**);
using CreateMemoryBufferFn = HRESULT(WINAPI*)(DWORD, IMFMediaBuffer**);
using CreateSampleFn = HRESULT(WINAPI*)(IMFSample**);

struct Functions {
    StartupFn startup = nullptr;
    ShutdownFn shutdown = nullptr;
    CreateAttributesFn createAttributes = nullptr;
    CreateSinkWriterFn createSinkWriter = nullptr;
    CreateMediaTypeFn createMediaType = nullptr;
    CreateMemoryBufferFn createMemoryBuffer = nullptr;
    CreateSampleFn createSample = nullptr;
    bool started = false;
};

Functions& Loaded() {
    static Functions functions;
    return functions;
}

template <typename T>
T Resolve(HMODULE module, const char* name) {
    return module ? reinterpret_cast<T>(reinterpret_cast<void*>(GetProcAddress(module, name))) : nullptr;
}

}  // namespace

bool Startup() {
    Functions& f = Loaded();
    if (f.started) return true;

    HMODULE platform = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE readWrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    f.startup = Resolve<StartupFn>(platform, "MFStartup");
    f.shutdown = Resolve<ShutdownFn>(platform, "MFShutdown");
    f.createAttributes = Resolve<CreateAttributesFn>(platform, "MFCreateAttributes");
    f.createMediaType = Resolve<CreateMediaTypeFn>(platform, "MFCreateMediaType");
    f.createMemoryBuffer = Resolve<CreateMemoryBufferFn>(platform, "MFCreateMemoryBuffer");
    f.createSample = Resolve<CreateSampleFn>(platform, "MFCreateSample");
    f.createSinkWriter = Resolve<CreateSinkWriterFn>(readWrite, "MFCreateSinkWriterFromURL");

    bool complete = f.startup && f.shutdown && f.createAttributes && f.createMediaType && f.createMemoryBuffer &&
                    f.createSample && f.createSinkWriter;
    f.started = complete && SUCCEEDED(f.startup(MF_VERSION, MFSTARTUP_FULL));
    return f.started;
}

void Shutdown() {
    Functions& f = Loaded();
    if (f.started) f.shutdown();
    f.started = false;
}

bool IsAvailable() {
    return Loaded().started;
}

HRESULT CreateAttributes(IMFAttributes** attributes, UINT32 initialSize) {
    return IsAvailable() ? Loaded().createAttributes(attributes, initialSize) : E_NOTIMPL;
}

HRESULT CreateSinkWriterFromURL(LPCWSTR url, IMFByteStream* stream, IMFAttributes* attributes, IMFSinkWriter** writer) {
    return IsAvailable() ? Loaded().createSinkWriter(url, stream, attributes, writer) : E_NOTIMPL;
}

HRESULT CreateMediaType(IMFMediaType** type) {
    return IsAvailable() ? Loaded().createMediaType(type) : E_NOTIMPL;
}

HRESULT CreateMemoryBuffer(DWORD maxLength, IMFMediaBuffer** buffer) {
    return IsAvailable() ? Loaded().createMemoryBuffer(maxLength, buffer) : E_NOTIMPL;
}

HRESULT CreateSample(IMFSample** sample) {
    return IsAvailable() ? Loaded().createSample(sample) : E_NOTIMPL;
}

}  // namespace space::mf
