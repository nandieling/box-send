; BoxSend Windows 安装包（Inno Setup 6.5+：x64compatible 要 6.3 起，简体中文语言文件要 6.5 起）
; 先跑 windows\build.ps1 生成 windows\publish\，再编译本脚本。
; 向导界面是简体中文：语言文件已随仓库带在 installer\Languages\ChineseSimplified.isl
; （抄自 jrsoftware/issrc 标签 is-6_7_1 的 Unofficial/ChineseSimplified.isl，补了 UTF-8 BOM，
; 没 BOM 时编译器按机器 ANSI 码页读，英文机器上中文全成问号）。Inno Setup 6.5 起可用。

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
AppId={{8C4B9E3A-7D15-4F0B-9C2E-51A7D3B6F110}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
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

[InstallDelete]
; 1.1 那版把核心库连同 Swift 运行时装在 {app}\native\ 子目录里（界面加载不到）。界面现在全放
; {app} 根目录，旧子目录留着只占 7 MB 还让人分不清哪份在用，升级时清掉
Type: filesandordirs; Name: "{app}\native"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
