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
; The payload is mostly already-compressed exes and a .pck; fast lzma2 keeps
; the compile quick for a near-identical size.
Compression=lzma2/fast
SolidCompression=no
WizardStyle=modern
UninstallDisplayIcon={app}\MotionFit.exe

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"

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
