; ============================================================================
; Qwen-Widget v2.0 - Windows NSIS Installer Script (.exe)
; ============================================================================
!include "MUI2.nsh"

Name "Qwen Widget v2.0"
OutFile "..\..\dist\QwenWidget-2.0.0-Setup-x64.exe"
InstallDir "$PROGRAMFILES64\QwenWidget"
RequestExecutionLevel admin

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "Spanish"
!insertmacro MUI_LANGUAGE "English"

Section "Qwen Widget Core (Lua + C++ + llama.cpp)" SecCore
  SetOutPath "$INSTDIR"
  File "..\..\README.md"
  File "..\..\CMakeLists.txt"

  SetOutPath "$INSTDIR\bin"
  File /nonfatal "..\..\bin\*.*"

  SetOutPath "$INSTDIR\lib"
  File /r "..\..\lib\*.*"

  SetOutPath "$INSTDIR\assets"
  File /r "..\..\assets\*.*"

  CreateDirectory "$INSTDIR\models"

  CreateDirectory "$SMPROGRAMS\Qwen Widget"
  CreateShortCut "$SMPROGRAMS\Qwen Widget\Qwen Widget.lnk" "$INSTDIR\bin\qwen-widget-bin.exe"
  CreateShortCut "$DESKTOP\Qwen Widget.lnk" "$INSTDIR\bin\qwen-widget-bin.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\Qwen Widget.lnk"
  RMDir /r "$SMPROGRAMS\Qwen Widget"
  RMDir /r "$INSTDIR"
SectionEnd
