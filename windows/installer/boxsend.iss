; BoxSend Windows 安装包（Inno Setup 6.3+，x64compatible 需要 6.3 起）
; 先跑 windows\build.ps1 生成 windows\publish\，再编译本脚本。
; 想让用户向导是中文：把 ChineseSimplified.isl 放进 installer\Languages\（Inno 官网 non-official 区）。

#define MyAppName "BoxSend"
; 版本由 build.ps1 从核心库 Version.swift 写进 version.inc，安装包名与界面里的版本号必然一致
#if FileExists(AddBackslash(SourcePath) + "version.inc")
  #include "version.inc"
#else
  #define MyAppVersion "1.0.0"
#endif
#define MyAppExeName "BoxSend.exe"
#define MyAppURL "https://github.com/nandieling/box-send"

; 自包含发布：.NET 运行时和 Swift 运行时都在包里，用户机器无需预装任何东西
[Setup]
; 解包约 160 MB，磁盘下限给 400 MB 余量
DiskSpaceMinimum=409600
AppId={{8C4B9E3A-7D15-4F0B-9C2E-51A7D3B6F110}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
VersionDisplayVersion={#MyAppVersion}
DefaultGroupName={#MyAppName}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputDir=Output
OutputBaseFilename={#MyAppName}-{#MyAppVersion}-win-x64
SetupIconFile=..\BoxSend.Windows\boxsend.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes
RestartApplications=no
; 用户数据在 %APPDATA%\BoxSend，卸载时默认保留，这里声明一下即可
UninstallFilesDir={app}

[Languages]
#if FileExists(AddBackslash(SourcePath) + "Languages\ChineseSimplified.isl")
Name: "zh"; MessagesFile: "Languages\ChineseSimplified.isl"
#else
Name: "zh"; MessagesFile: "compiler:Default.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
