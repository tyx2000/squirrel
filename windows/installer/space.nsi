; Purpose: Per-user installer for Space on Windows. No administrator rights are needed: it
; installs to %LOCALAPPDATA%\Programs\Space, adds a Start menu shortcut and an Apps &
; features entry, and its uninstaller closes a running copy and removes the login item.
;
; Built by build.sh, which defines VERSION, SOURCE_DIR, ICON and OUTFILE.

Unicode true

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "WinMessages.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

!ifndef VERSION
  !define VERSION "1.0.0"
!endif
!ifndef SOURCE_DIR
  !define SOURCE_DIR "..\build"
!endif
!ifndef ICON
  !define ICON "..\res\space.ico"
!endif
!ifndef OUTFILE
  !define OUTFILE "..\build\Space-setup.exe"
!endif

!define APP_NAME "Space"
!define PUBLISHER "onmyown"
!define APP_KEY "Software\Space"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Space"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define STARTUP_APPROVED_KEY "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
; The class of Space's hidden window; WM_CLOSE to it quits the app cleanly.
!define MESSAGE_WINDOW_CLASS "SpaceMessageWindow"

Name "${APP_NAME}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
InstallDirRegKey HKCU "${APP_KEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ManifestDPIAware true
ManifestSupportedOS Win10
BrandingText "${APP_NAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP_NAME} Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "${PUBLISHER}"

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TEXT "Space keeps a clipboard history, arranges windows, captures areas of the screen and records it, all from shortcuts and the notification area.$\r$\n$\r$\nSetup installs Space for your account only and does not need administrator rights.$\r$\n$\r$\nClick Next to continue."
!define MUI_FINISHPAGE_RUN "$INSTDIR\Space.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start Space"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

!macro CloseRunningSpace
  FindWindow $0 "${MESSAGE_WINDOW_CLASS}" ""
  ${If} $0 <> 0
    DetailPrint "Closing the running copy of Space..."
    SendMessage $0 ${WM_CLOSE} 0 0 /TIMEOUT=5000
    ; Give a recording in progress time to be written out.
    StrCpy $1 0
    ${Do}
      Sleep 250
      IntOp $1 $1 + 1
      FindWindow $0 "${MESSAGE_WINDOW_CLASS}" ""
      ${If} $0 = 0
      ${OrIf} $1 >= 40
        ${ExitDo}
      ${EndIf}
    ${Loop}
  ${EndIf}
!macroend

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Space needs 64-bit Windows."
    Abort
  ${EndIf}
  ; Windows.Graphics.Capture and per-monitor DPI v2 arrived in Windows 10 version 1903.
  ${IfNot} ${AtLeastWin10}
  ${OrIfNot} ${AtLeastBuild} 18362
    MessageBox MB_OK|MB_ICONSTOP "Space needs Windows 10 version 1903 or later."
    Abort
  ${EndIf}
FunctionEnd

Section "Space" SecMain
  SectionIn RO
  !insertmacro CloseRunningSpace

  SetOutPath "$INSTDIR"
  File "${SOURCE_DIR}\Space.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateShortcut "$SMPROGRAMS\Space.lnk" "$INSTDIR\Space.exe" "" "$INSTDIR\Space.exe" 0

  WriteRegStr HKCU "${APP_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\Space.exe,0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" "$0"

  ; Open at Login points at the executable; keep it pointing at this copy.
  ReadRegStr $0 HKCU "${RUN_KEY}" "${APP_NAME}"
  ${If} $0 != ""
    WriteRegStr HKCU "${RUN_KEY}" "${APP_NAME}" '"$INSTDIR\Space.exe"'
  ${EndIf}
SectionEnd

Section "Uninstall"
  !insertmacro CloseRunningSpace

  Delete "$INSTDIR\Space.exe"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Space.lnk"

  DeleteRegValue HKCU "${RUN_KEY}" "${APP_NAME}"
  DeleteRegValue HKCU "${STARTUP_APPROVED_KEY}" "${APP_NAME}"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "${APP_KEY}"

  MessageBox MB_YESNO|MB_ICONQUESTION "Also delete your clipboard history and Space settings?" /SD IDNO IDNO keepData
    RMDir /r "$LOCALAPPDATA\Space"
  keepData:
SectionEnd
