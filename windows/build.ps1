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
$win   = $PSScriptRoot
$root  = Split-Path -Parent $win
$proj  = Join-Path $win 'BoxSend.Windows'
$native = Join-Path $proj 'native'
$out   = Join-Path $win 'publish'

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

# 版本号只有一个来源：核心库里的 BoxSendVersion
$verFile = Join-Path $root 'Sources\BoxSendKit\Util\Version.swift'
$verMatch = Select-String -Path $verFile -Pattern 'static let version = "([^"]+)"' | Select-Object -First 1
if (-not $verMatch) { throw '没能从 Version.swift 里读出版本号' }
$ver = $verMatch.Matches[0].Groups[1].Value
Write-Host ("BoxSend " + $ver) -ForegroundColor Green

# ---------- 1. 核心库 ----------
if (-not $SkipCore) {
    Step "swift build -c $Cfg --product boxsend"
    Push-Location $root
    try { & swift build -c $Cfg --product boxsend; if ($LASTEXITCODE) { throw "swift build 失败" } }
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
# 自带运行时 = 成品涨到 160 MB 上下，换来的是「用户不用装 .NET」；不带则 1 MB 内，但要预装桌面运行时
$sc = if ($FrameworkDependent) { 'false' } else { 'true' }
& dotnet publish $proj -c Release -r win-x64 --self-contained $sc -o $out `
    -p:Version=$ver -p:DebugType=none -p:DebugSymbols=false
if ($LASTEXITCODE) { throw "dotnet publish 失败" }

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
