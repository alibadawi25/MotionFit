; MotionFit offline installer (Inno Setup 6).
; Compiled by tools/build_release.py AFTER the release folder is built:
;   ISCC /DSourceDir=<build\MotionFit> /O<build> tools\installer.iss
; Produces build\MotionFit-Setup.exe - a single setup wizard friends can run:
; installs per-user (no admin/UAC prompt), adds Start-menu + optional desktop
; shortcuts, and registers a normal Windows uninstaller.

#ifndef SourceDir
  #define SourceDir "..\build\MotionFit"
#endif

[Setup]
AppId={{B7E3D9A4-2F61-4C58-9B0D-8E5A1C6F4D20}
AppName=MotionFit
AppVersion=1.0
DefaultDirName={localappdata}\MotionFit
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputBaseFilename=MotionFit-Setup
; Max lzma2 + solid: the payload is a few hundred MB of exe/dll (compresses
; well) and a friend downloads this file - a few extra build minutes buys a
; meaningfully smaller transfer.
Compression=lzma2/max
SolidCompression=yes
; Compress in parallel blocks: costs ~1-2% ratio, cuts an ~86 min single-
; threaded compile on this machine down to minutes.
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=6
WizardStyle=modern
UninstallDisplayIcon={app}\MotionFit.exe
#define IconFile "..\build\icons\motionfit.ico"
#if FileExists(IconFile)
SetupIconFile={#IconFile}
#endif

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"

[InstallDelete]
; The PyInstaller bundle's file set changes between releases and Inno never
; removes superseded files on upgrade - stale dlls/pyds bloat the install and
; can shadow the new bundle. Wipe it and let this install lay it down fresh.
Type: filesandordirs; Name: "{app}\pose_server\_internal"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "pose_server.log"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{userprograms}\MotionFit"; Filename: "{app}\MotionFit.exe"
Name: "{userdesktop}\MotionFit"; Filename: "{app}\MotionFit.exe"; Tasks: desktopicon

[UninstallDelete]
; Written by the launcher at runtime, so the uninstaller doesn't know about it.
Type: files; Name: "{app}\pose_server.log"

[Run]
Filename: "{app}\MotionFit.exe"; Description: "Play MotionFit now"; Flags: nowait postinstall skipifsilent
