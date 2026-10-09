// Purpose: Loads Media Foundation at run time. Windows N editions ship without it until the
// Media Feature Pack is installed; linking it directly would stop Space from starting at
// all there, when only recording needs it.

#pragma once

#include "common.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>

namespace space::mf {

// Loads the DLLs and calls MFStartup; false if Media Foundation is unavailable.
bool Startup();
void Shutdown();
bool IsAvailable();

HRESULT CreateAttributes(IMFAttributes** attributes, UINT32 initialSize);
HRESULT CreateSinkWriterFromURL(LPCWSTR url, IMFByteStream* stream, IMFAttributes* attributes, IMFSinkWriter** writer);
HRESULT CreateMediaType(IMFMediaType** type);
HRESULT CreateMemoryBuffer(DWORD maxLength, IMFMediaBuffer** buffer);
HRESULT CreateSample(IMFSample** sample);

}  // namespace space::mf
