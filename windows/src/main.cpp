// Purpose: Entry point: keeps a single instance, initialises COM and Media Foundation, and
// runs the app.

#include "app.h"
#include "common.h"
#include "media_foundation.h"

#include <commctrl.h>

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    // The manifest asks for per-monitor DPI awareness; this covers a missing manifest.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // A second launch (from the Start menu, say) opens the running copy's panel instead,
    // the counterpart of reopening a Mac app from the Dock.
    HANDLE instanceMutex = CreateMutexW(nullptr, TRUE, L"Local\\Space.SingleInstance.6E1D6C4B");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        if (HWND running = FindWindowW(space::kMessageWindowClass, nullptr)) {
            DWORD processId = 0;
            GetWindowThreadProcessId(running, &processId);
            AllowSetForegroundWindow(processId);
            PostMessageW(running, space::WM_APP_OPEN_PANEL, 0, 0);
        }
        if (instanceMutex) CloseHandle(instanceMutex);
        return 0;
    }

    HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    // Only recording needs it; without it the rest of the app still runs.
    space::mf::Startup();
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES};
    InitCommonControlsEx(&controls);

    int result = space::App::Instance().Run(instance);

    space::mf::Shutdown();
    if (SUCCEEDED(com)) CoUninitialize();
    if (instanceMutex) CloseHandle(instanceMutex);
    return result;
}
