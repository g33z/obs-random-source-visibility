; NSIS installer script for obs-random-source-visibility.
;
; Built with makensis (Linux: apt install nsis; macOS: brew install makensis) -
; makensis itself cross-builds the Windows installer .exe from Linux/macOS,
; same as the plugin .dll is cross-compiled; nothing runs on actual Windows
; until the resulting installer is executed there.
;
; Reads the already-staged output of `make stage-windows` (STAGE_DIR below),
; so it has no knowledge of how the plugin was built - only where its files
; ended up. All values are supplied at build time via -D command-line
; defines (see Makefile's package-windows target) rather than hardcoded, so
; this script has no version string of its own to keep in sync.

!ifndef PLUGIN_NAME
  !error "PLUGIN_NAME must be defined via -DPLUGIN_NAME=..."
!endif
!ifndef PLUGIN_VERSION
  !error "PLUGIN_VERSION must be defined via -DPLUGIN_VERSION=..."
!endif
!ifndef STAGE_DIR
  !error "STAGE_DIR must be defined via -DSTAGE_DIR=..."
!endif
!ifndef OUT_FILE
  !error "OUT_FILE must be defined via -DOUT_FILE=..."
!endif

Unicode true

!include "MUI2.nsh"

Name "${PLUGIN_NAME}"
OutFile "${OUT_FILE}"

; C:\ProgramData\obs-studio\plugins\<name> is OBS's current recommended
; manual-install location (obsproject.com/kb/plugins-guide) - it superseded
; the old %APPDATA%\obs-studio\plugins\ per-user convention, and unlike
; Program Files it doesn't require admin elevation to write to.
InstallDir "$COMMONPROGRAMDATA\obs-studio\plugins\${PLUGIN_NAME}"
RequestExecutionLevel user

!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; HKCU (not HKLM) to match RequestExecutionLevel user above - never mix
; HKLM/$ProgramFiles-style all-machine registration with a
; RequestExecutionLevel that isn't admin. Known tradeoff: since $INSTDIR
; is shared (all users on the machine), a second Windows user who runs
; this installer gets their own HKCU uninstall entry pointing at those
; same shared files; whichever user uninstalls first removes the files
; out from under the other user's now-stale entry. Not handled - out of
; scope for a single-user-machine hobby plugin.
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PLUGIN_NAME}"

Section "Install"
  SetOutPath "$INSTDIR\bin\64bit"
  File "${STAGE_DIR}/obs-plugins/64bit/${PLUGIN_NAME}.dll"

  SetOutPath "$INSTDIR\data"
  File /r "${STAGE_DIR}/data/obs-plugins/${PLUGIN_NAME}/*.*"

  WriteUninstaller "$INSTDIR\uninstall.exe"

  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${PLUGIN_NAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${PLUGIN_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\bin\64bit\${PLUGIN_NAME}.dll"
  RMDir "$INSTDIR\bin\64bit"
  RMDir "$INSTDIR\bin"
  RMDir /r "$INSTDIR\data"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "${UNINST_KEY}"
SectionEnd
