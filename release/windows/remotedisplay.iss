; Instalador Windows de Remote Display (Inno Setup 6).
; Lo invoca tools/release-windows.ps1 pasando /DAppVersion=x.y.z /DSourceDir=<Release> /DOutDir=<out>
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\client\build\windows\x64\runner\Release"
#endif
#ifndef OutDir
  #define OutDir "..\out"
#endif

[Setup]
AppId={{A7C4D3E2-9B1F-4E6A-8C2D-5F0E1B7A9D31}
AppName=Remote Display
AppVersion={#AppVersion}
AppVerName=Remote Display {#AppVersion}
AppPublisher=Samuel Rioja
DefaultDirName={autopf}\Remote Display
DefaultGroupName=Remote Display
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\remotedisplay.exe
OutputDir={#OutDir}
OutputBaseFilename=RemoteDisplay-Setup-{#AppVersion}
SetupIconFile=..\..\client\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Remote Display"; Filename: "{app}\remotedisplay.exe"
Name: "{autodesktop}\Remote Display"; Filename: "{app}\remotedisplay.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\remotedisplay.exe"; Description: "{cm:LaunchProgram,Remote Display}"; Flags: nowait postinstall skipifsilent
