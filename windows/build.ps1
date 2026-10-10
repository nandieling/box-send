<#
Windows 打包脚本（在 Windows 上运行，PowerShell 7 或 Windows PowerShell 5.1 均可）

  .\windows\build.ps1              # release：核心库 -> native\ -> WPF -> publish\
  .\windows\build.ps1 -Setup       # 再打成 installer\Output\*.exe
  .\windows\build.ps1 -Cfg debug   # 调试用
  .\windows\build.ps1 -FrameworkDependent   # 不带 .NET 运行时（成品小，但用户机器要自己装）

默认自带 .NET 运行时：用户机器上什么都不用装，双击就跑。
前置：Swift for Windows 工具链（https://www.swift.org/install/windows/）、.NET 8 SDK、
      需要安装包时再装 Inno Setup 6。
#>
param(
    [ValidateSet('debug', 'release')] [string]$Cfg = 'release',
    [switch]$Setup,
    [switch]$SkipCore,
    [switch]$FrameworkDependent
)

$ErrorActionPreference = 'Stop'
# 外部命令的非零退出码一律交给下面的 $LASTEXITCODE 判，别让 PS 7.4+ 提前抛异常打断重试
$PSNativeCommandUseErrorActionPreference = $false
# CI 里跑时别被首次运行欢迎语、遥测、ASP.NET 开发证书这些额外动作拖住
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$win   = $PSScriptRoot
$root  = Split-Path -Parent $win
$proj  = Join-Path $win 'BoxSend.Windows'
$native = Join-Path $proj 'native'
$out   = Join-Path $win 'publish'

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

# 把 Visual Studio 开发者环境（INCLUDE / LIB / LIBPATH / WindowsSdkDir 等）导进当前进程。
# Swift for Windows 编译时要靠这些定位 MSVC 与 Windows SDK：Swift 官方安装器只往用户环境里
# 写了 SDKROOT，剩下的路径得靠 VsDevCmd。找不到 VS 就返回 $false，由调用方决定怎么办。
function Import-VsDevEnvironment {
    if ($env:INCLUDE -and $env:LIB) { return $false }      # 已经在开发者环境里，没东西可导
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $vswhere = if ($pf86) { Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe' } else { $null }
    if (-not $vswhere -or -not (Test-Path $vswhere)) { return $false }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
          -property installationPath | Select-Object -First 1
    if (-not $vs) { return $false }
    $dev = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path $dev)) { return $false }
    # 借一个临时 .bat 把 VsDevCmd 设的变量打印出来，省掉往 cmd /c 里套引号
    $bat = Join-Path ([IO.Path]::GetTempPath()) 'boxsend-vsenv.bat'
    Set-Content -Path $bat -Encoding Ascii -Value "@echo off`r`ncall `"$dev`" -arch=amd64 -no_logo`r`nset"
    foreach ($line in (& $env:ComSpec /c $bat)) {
        if ($line -match '^([^=]+)=(.*)$') { Set-Item -LiteralPath ('env:' + $Matches[1]) -Value $Matches[2] }
    }
    Remove-Item $bat -ErrorAction SilentlyContinue
    return $true
}

# 跑 swift build 并只回显关键行。swift build 失败时会把整条前端编译命令打出来（几十 KB），
# 真正的报错行被冲得看不见，这里只留 error/warning/进度行；失败时再补输出结尾 30 行。
function Invoke-SwiftBuild($cfg) {
    $lines = @(& swift build -c $cfg --product boxsend 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    foreach ($l in $lines) {
        if ($l -notmatch 'error|warning|Build complete|Linking|Compiling') { continue }
        if ($l.Length -gt 300) { Write-Host ($l.Substring(0, 300) + ' …') } else { Write-Host $l }
    }
    if ($code) {
        Write-Host '-- 输出结尾 --' -ForegroundColor DarkGray
        $lines | Select-Object -Last 30 | ForEach-Object {
            if ($_.Length -gt 300) { Write-Host ($_.Substring(0, 300) + ' …') } else { Write-Host $_ }
        }
    }
    return $code
}

# 版本号只有一个来源：核心库里的 BoxSendVersion
$verFile = Join-Path $root 'Sources\BoxSendKit\Util\Version.swift'
$verMatch = Select-String -Path $verFile -Pattern 'static let version = "([^"]+)"' | Select-Object -First 1
if (-not $verMatch) { throw '没能从 Version.swift 里读出版本号' }
$ver = $verMatch.Matches[0].Groups[1].Value
Write-Host ("BoxSend " + $ver) -ForegroundColor Green

# ---------- 1. 核心库 ----------
if (-not $SkipCore) {
    Step "swift build -c $Cfg --product boxsend"
    # Windows 上 Swift 的标准库不在工具链里，而在 SDKROOT 指向的 Windows.sdk，
    # 这个环境变量是 Swift 安装器写进用户环境的，装完工具链不换终端就读不到
    if ($IsWindows -and -not $env:SDKROOT) {
        Write-Warning '读不到环境变量 SDKROOT（Swift 靠它定位 Windows 平台标准库）。若是刚装完工具链，请重开一个终端再跑。'
    }
    Push-Location $root
    try {
        $code = Invoke-SwiftBuild $Cfg
        if ($code) {
            # 编译没过的话，补上 VS 开发者环境再试一次（MSVC 头文件与库的路径只在里面有）
            if (-not (Import-VsDevEnvironment)) { throw "swift build 失败（退出码 $code）" }
            Write-Host '已导入 VS 开发者环境，重试一次' -ForegroundColor Yellow
            $code = Invoke-SwiftBuild $Cfg
            if ($code) { throw "swift build 失败（导入 VS 开发者环境后仍没过，退出码 $code）" }
        }
    }
    finally { Pop-Location }

    $built = Join-Path $root ".build\$Cfg"
    if (-not (Test-Path (Join-Path $built 'boxsend.dll'))) {
        throw "没找到 $built\boxsend.dll"
    }

    Step '把核心库和 Swift 运行时 DLL 收进 native\'
    New-Item -ItemType Directory -Force -Path $native | Out-Null
    Get-ChildItem $native -Filter *.dll | Remove-Item

    Copy-Item (Join-Path $built 'boxsend.dll') $native

    # Swift 6 的 Windows 发行包是分家的：swift.exe 在 Toolchains\...\usr\bin，
    # swiftCore.dll / Foundation.dll 这些运行时在 Runtimes\...\usr\bin，只扫前者会拷不全。
    # 做法是把「PATH 里有 swiftCore.dll 的目录」都算进来，再加 Toolchains 旁边那个 Runtimes。
    $toolchainBin = Split-Path -Parent (Get-Command swift).Source
    $bins = New-Object System.Collections.Generic.List[string]
    $bins.Add($toolchainBin)
    foreach ($dir in ($env:Path -split ';')) {
        if ($dir -and (Test-Path (Join-Path $dir 'swiftCore.dll'))) { $bins.Add($dir) }
    }
    # PATH 没配全时退一步：拿 Toolchains 同级的 Runtimes 根目录，逐个版本目录找 usr\bin
    # （Toolchains 的目录名带 +Asserts 后缀，Runtimes 的不带，别指望直接字符串替换）
    $rtRoot = $toolchainBin -replace '\\Toolchains\\.*$', '\Runtimes'
    if (Test-Path $rtRoot) {
        Get-ChildItem $rtRoot -Directory | ForEach-Object {
            $b = Join-Path $_.FullName 'usr\bin'
            if (Test-Path $b) { $bins.Add($b) }
        }
    }
    $bins = $bins | Select-Object -Unique

    # 文件名跟着工具链版本变，按模式扫，命中多少拷多少；漏拷时 Windows 会直接报缺哪个 DLL。
    $patterns = @('swiftrt.dll', 'swiftCore.dll', 'swift*-*.dll', 'swiftWinSDK.dll', 'swiftCXX.dll',
                  'dispatch.dll', 'BlocksRuntime.dll', 'Foundation*.dll', 'FoundationXML.dll',
                  'icu*.dll', 'curl*.dll', 'zlib*.dll', 'xml2.dll', 'sqlite3.dll', 'mimalloc.dll')
    $copied = @()
    foreach ($bin in $bins) {
        Write-Host ('  扫描 ' + $bin)
        foreach ($p in $patterns) {
            Get-ChildItem -Path $bin -Filter $p -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not (Test-Path (Join-Path $native $_.Name))) {
                    Copy-Item $_.FullName $native
                    $copied += $_.Name
                }
            }
        }
    }
    # Swift 运行时是 MSVC 编的，可能要 VCRUNTIME140；.NET 自包含只带它自己那份 _cor3。
    # 随包放一份 app-local 的最保险，否则干净的 Win11 上表现是「双击没反应」。
    foreach ($crt in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
        $sys = Join-Path $env:SystemRoot "System32\$crt"
        if ((Test-Path $sys) -and -not (Test-Path (Join-Path $native $crt))) {
            Copy-Item $sys $native
            $copied += $crt
        }
    }

    Write-Host ("核心库 + 运行时依赖共 " + (1 + $copied.Count) + " 个 DLL：")
    Get-ChildItem $native -Filter *.dll | ForEach-Object { Write-Host ("  " + $_.Name + "  " + [math]::Round($_.Length / 1kb) + " KB") }
    Write-Host '提示：漏依赖的权威判据是 boxsend.dll 的导入表，可用 dumpbin /dependents 核对。'
}

# ---------- 2. WPF 界面 ----------
Step 'dotnet publish BoxSend.Windows'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
Write-Host ('dotnet SDK ' + (dotnet --version))
# 自带运行时 = 成品涨到 190 MB 上下，换来的是「用户不用装 .NET」；不带则 1 MB 内，但要预装桌面运行时
$sc = if ($FrameworkDependent) { 'false' } else { 'true' }
# 还原单独一步：自包含发布要从 nuget.org 拉 .NET 与 WindowsDesktop 的 win-x64 运行时包（上百 MB），
# 网络卡住时整步可以半小时不出一个字，所以 restore 与 publish 分开跑、各自计时、用 minimal 级别
$t = [Diagnostics.Stopwatch]::StartNew()
& dotnet restore $proj -r win-x64 -v minimal
if ($LASTEXITCODE) { throw "dotnet restore 失败（退出码 $LASTEXITCODE）" }
Write-Host ('还原完成，用时 ' + [int]$t.Elapsed.TotalSeconds + ' 秒')
$t.Restart()
& dotnet publish $proj -c Release -r win-x64 --self-contained $sc -o $out --no-restore -v minimal `
    -p:Version=$ver -p:DebugType=none -p:DebugSymbols=false
if ($LASTEXITCODE) { throw "dotnet publish 失败（退出码 $LASTEXITCODE）" }
Write-Host ('发布完成，用时 ' + [int]$t.Elapsed.TotalSeconds + ' 秒')

# ---------- 2.5 加载冒烟 ----------
# 核心库少拷一个运行时 DLL，表现是用户「双击没反应」，界面上什么提示都没有。
# 这里在打包前用 LoadLibraryEx 真加载一次（0x8 = 按 DLL 所在目录找依赖），再核对 C ABI 导出符号。
Step '加载 boxsend.dll 冒烟测试'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BoxSendLoad {
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryEx(string path, IntPtr reserved, uint flags);
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string name);
}
'@
$dll = Join-Path $out 'boxsend.dll'
$h = [BoxSendLoad]::LoadLibraryEx($dll, [IntPtr]::Zero, 0x8)
if (-not $h) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "加载 $dll 失败（$(New-Object ComponentModel.Win32Exception $err)）——十有八九是 native\ 里少拷了依赖 DLL"
}
$missing = @('boxsend_create', 'boxsend_invoke', 'boxsend_free', 'boxsend_set_ocr',
             'boxsend_version', 'boxsend_destroy', 'boxsend_last_error') |
           Where-Object { -not [BoxSendLoad]::GetProcAddress($h, $_) }
if ($missing) { throw ('导出符号缺失：' + ($missing -join ', ')) }
Write-Host '加载成功，7 个导出符号齐全'

# ---------- 3. 体积概览 ----------
Step '成品体积'
$total = (Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum
$files = (Get-ChildItem $out -Recurse -File).Count
Write-Host ("publish\ 合计 {0} MB / {1} 个文件（自包含含 .NET 运行时；安装包压缩后约为其 1/3）" `
            -f [math]::Round($total / 1mb, 1), $files)
Get-ChildItem $out -File | Sort-Object Length -Descending | Select-Object -First 8 |
    ForEach-Object { Write-Host ("  {0,8} KB  {1}" -f [math]::Round($_.Length / 1kb), $_.Name) }

# ---------- 4. 安装包 ----------
if ($Setup) {
    Step 'Inno Setup'
    # $env:ProgramFiles(x86) 要写成 ${env:...}，否则括号被当字面量
    $cand = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
              "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
              "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")
    $iscc = $cand | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) {
        throw '没找到 ISCC.exe。装 Inno Setup 6（默认路径即可）后重跑；也可以先只交付 publish\ 目录，绿色版能直接用。'
    }
    Write-Host ('用 ' + $iscc)
    # 版本号交给 iss（走文件而不是命令行参数，省掉 PowerShell 传参的引号坑）
    [IO.File]::WriteAllText((Join-Path $win 'installer\version.inc'),
                            '#define MyAppVersion "' + $ver + '"' + [Environment]::NewLine)
    & $iscc (Join-Path $win 'installer\boxsend.iss')
    if ($LASTEXITCODE) { throw 'Inno Setup 打包失败' }
    Get-ChildItem (Join-Path $win 'installer\Output') -Filter *.exe |
        ForEach-Object { Write-Host ("安装包 " + $_.Name + "  " + [math]::Round($_.Length / 1mb, 1) + " MB") }
}

Write-Host "`n完成。" -ForegroundColor Green
