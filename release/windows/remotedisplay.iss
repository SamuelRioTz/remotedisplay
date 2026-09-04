; Windows installer for Remote Display (Inno Setup 6).
; Invoked by tools/release-windows.ps1 passing /DAppVersion=x.y.z /DSourceDir=<Release> /DOutDir=<out>
#ifndef AppVersion
  #define AppVersion "1.0.3"
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
LicenseFile=..\..\LICENSE
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

[Registry]
; remotedisplay:// deep links (the engine derives the scheme from APP_NAME, see get_uri_prefix()).
Root: HKA; Subkey: "Software\Classes\remotedisplay"; ValueType: string; ValueName: ""; ValueData: "URL:Remote Display"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\remotedisplay"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\remotedisplay\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\remotedisplay.exe,0"
Root: HKA; Subkey: "Software\Classes\remotedisplay\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\remotedisplay.exe"" ""%1"""

[Run]
Filename: "{app}\remotedisplay.exe"; Description: "{cm:LaunchProgram,Remote Display}"; Flags: nowait postinstall skipifsilent
