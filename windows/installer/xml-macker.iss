; Inno Setup 6 script, builds xml-macker-setup-1.0.0.exe from the published single file.
; 1. dotnet publish ... -o publish   (see README)      2. iscc installer\xml-macker.iss

#define MyAppName "xml-macker"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Ahmed SM Sobhy, KAIST IAM Group"
#define MyAppExeName "xml-macker.exe"

[Setup]
AppId={{443E2FD5-316C-4190-BB57-D160F88FEB63}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\src\xml-macker\Resources\xml-macker.ico
OutputDir=Output
OutputBaseFilename=xml-macker-setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "openwith"; Description: "Show xml-macker in the ""Open with"" list for .xml files"; GroupDescription: "File types:"; Flags: unchecked

[Files]
Source: "..\publish\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\Applications\{#MyAppExeName}"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "{#MyAppName}"; Flags: uninsdeletekey; Tasks: openwith
Root: HKA; Subkey: "Software\Classes\Applications\{#MyAppExeName}\shell\open\command"; ValueType: string; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey; Tasks: openwith
Root: HKA; Subkey: "Software\Classes\.xml\OpenWithList\{#MyAppExeName}"; ValueType: none; Flags: uninsdeletekey; Tasks: openwith

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
