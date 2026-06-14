; Inno Setup script for the Chess (disguised VPN) Windows app.
;
; WHY an installer instead of a loose zip: a zip unpacked into a user-writable folder
; (Downloads, Desktop) lets a local attacker plant a malicious wintun.dll / system DLL
; next to chess.exe / sing-box.exe; since the core runs elevated, that DLL would execute
; with admin rights (DLL-planting privilege escalation). Installing into Program Files —
; which a non-admin cannot write to — removes that planting surface entirely.
;
; Compiled in CI (see .github/workflows/windows.yml). Pass the version with
;   ISCC /DAppVer=1.3.2 chess-installer.iss

#ifndef AppVer
  #define AppVer "0.0.0"
#endif

[Setup]
AppName=Chess
AppVersion={#AppVer}
DefaultDirName={autopf}\Chess
DefaultGroupName=Chess
UninstallDisplayName=Chess
; Force a Program Files (admin-only) install — this is the whole point.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=.
OutputBaseFilename=chess-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
; Everything the CI staged into the Release folder (chess.exe, sing-box.exe, wintun.dll,
; flutter dlls, data\). Installed read-only for non-admins by virtue of the location.
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Chess"; Filename: "{app}\chess.exe"
Name: "{commondesktop}\Chess"; Filename: "{app}\chess.exe"

[Run]
Filename: "{app}\chess.exe"; Description: "Запустить Chess"; Flags: nowait postinstall skipifsilent
