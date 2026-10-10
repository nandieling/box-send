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

[Setup]
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

[Code]
// .NET 8+ 桌面运行时缺失时给出人话提示（自包含包不需要这段）
function DesktopRuntimeInstalled: Boolean;
var
  Names: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if not RegGetValueNames(HKLM64, 'SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedruntime', Names) then
    Exit;
  for I := 0 to GetArrayLength(Names) - 1 do
    if Pos('Microsoft.WindowsDesktop.App', Names[I]) > 0 then
      Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    if not DesktopRuntimeInstalled then
      MsgBox('本机还没装 .NET 8 桌面运行时（Windows Desktop Runtime）。' + #13#10 +
             '如果双击 BoxSend.exe 没反应，去微软官网下载 x64 版 Desktop Runtime 装上即可。' + #13#10 +
             'https://dotnet.microsoft.com/download/dotnet/8.0',
             mbInformation, MB_OK);
end;
