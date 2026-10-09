# Space for Windows

A native Windows port of the macOS app in `../Space`, written in C++ against Win32,
Direct2D/DirectWrite, WIC, Windows.Graphics.Capture, Media Foundation and WASAPI. It is one
self-contained `Space.exe` (about 1 MB) with no runtime to install.

Requires 64-bit Windows 10 version 1903 or later.

## Building

On macOS, with Homebrew's `mingw-w64` and `makensis`:

```bash
./build.sh
```

This writes `build/Space.exe` and the installer
`../dist/Space-1.0-windows-x64-<date>-<time>-setup.exe`. `./build.sh exe` builds only the
executable. `tools/make_icon.sh` regenerates `res/space.ico` from the Mac app icon.

On Windows, `CMakeLists.txt` builds the same sources with Visual Studio or MinGW. The
cross-build above is the one that has been built; the CMake build has not been tried yet.

## The installer

A per-user NSIS installer: no administrator rights, installs to
`%LOCALAPPDATA%\Programs\Space`, adds a Start menu shortcut and an Apps & features entry.
Re-running it upgrades in place and closes a running copy first. The uninstaller removes the
Open at Login entry and asks before deleting history and settings.

## What maps to what

| macOS | Windows |
| --- | --- |
| Menu bar item (🌃), red pill with the elapsed time while recording | Notification-area icon (🌃, drawn from Segoe UI Emoji); while recording, a red icon and a red time pill at the top of the recorded screen. The pill is left out of the recording. Clicking either one stops the recording. |
| Non-activating floating panel, 1080×720 | Topmost tool window (no taskbar button), same layout, drawn with Direct2D |
| Carbon hotkeys; ⌃ ⌥ ⇧ ⌘ | `RegisterHotKey`; Ctrl, Alt, Shift and Win |
| NSPasteboard polling, nspasteboard.org privacy markers | `WM_CLIPBOARDUPDATE`; `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` and `Clipboard Viewer Ignore` |
| Paste with ⌘V via Accessibility | Gives the keyboard back to the previous window, then sends Ctrl+V with `SendInput` |
| Accessibility window moves | `SetWindowPos`, adjusted for the invisible resize borders |
| Toggle Full Screen | Toggle Maximize (Windows has no system-wide full-screen mode) |
| ScreenCaptureKit area capture | GDI capture of the screen under the pointer, frozen in a Direct2D overlay |
| ScreenCaptureKit recording to MP4 | Windows.Graphics.Capture → H.264 with Media Foundation; system audio from WASAPI loopback → AAC |
| SMAppService login item | `HKCU\...\Run`, honouring the Startup apps switch in Settings |
| `~/Library/Application Support/Space` | `%LOCALAPPDATA%\Space` |

### Default shortcuts

| Command | Shortcut |
| --- | --- |
| Show Clipboard History | Ctrl+Alt+V |
| Window Left / Right / Center Two Thirds | Ctrl+Alt+Win+← / → / ↓ |
| Toggle Maximize | Ctrl+Alt+Win+F |
| Move Window Left / Center / Right | Ctrl+Alt+Shift+← / ↓ / → |
| Lock Screen | Ctrl+Alt+Win+L |
| Capture Area | Ctrl+Alt+Win+C |
| Record Screen | Ctrl+Alt+Win+R |

### Differences from the Mac build

- Windows has no permission prompts for any of this, so the Accessibility and Screen
  Recording guidance is gone. Windows of apps running as administrator can only be arranged
  or pasted into while Space also runs as administrator.
- When a copy holds both text and a picture of that text (Office does this), history keeps
  the text. The Mac build keeps the picture.
- A pinned screenshot can also be closed from its right-click menu.
- Recording runs at 30 frames per second. Frames are fitted within 4096×2304, the largest
  size the Media Foundation H.264 encoder accepts.
- On Windows N editions, recording needs the Media Feature Pack; everything else works
  without it.
