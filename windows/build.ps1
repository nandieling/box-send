<#
Windows 打包脚本（在 Windows 上运行，PowerShell 7 或 Windows PowerShell 5.1 均可）

  .\windows\build.ps1              # release：核心库 -> native\ -> WPF -> publish\
  .\windows\build.ps1 -Cfg debug   # 调试用
  .\windows\build.ps1 -Setup       # 最后再用 Inno Setup 打成安装包

前置：Swift for Windows 工具链（https://www.swift.org/install/windows/）、.NET 8 SDK、
      需要安装包时再装 Inno Setup 6。
#>
param(
    [ValidateSet('debug', 'release')] [string]$Cfg = 'release',
    [switch]$Setup,
    [switch]$SkipCore
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

    # Swift 工具链的运行时与依赖。不同版本文件名有出入：按模式扫，命中多少拷多少，
    # 最终以「拷过去能跑起来」为准；漏拷时 Windows 会直接报「找不到 XXX.dll」，照名补即可。
    $toolchainBin = Split-Path -Parent (Get-Command swift).Source
    $patterns = @('swiftrt.dll', 'swiftCore.dll', 'swift*-*.dll', 'swiftWinSDK.dll', 'swiftCXX.dll',
                  'dispatch.dll', 'BlocksRuntime.dll', 'Foundation*.dll', 'FoundationXML.dll',
                  'icu*.dll', 'curl*.dll', 'zlib*.dll', 'xml2.dll', 'sqlite3.dll')
    $copied = @()
    foreach ($p in $patterns) {
        Get-ChildItem -Path $toolchainBin -Filter $p -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not (Test-Path (Join-Path $native $_.Name))) {
                Copy-Item $_.FullName $native
                $copied += $_.Name
            }
        }
    }
    Write-Host ("核心库 + 运行时依赖共 " + (1 + $copied.Count) + " 个 DLL：")
    Get-ChildItem $native -Filter *.dll | ForEach-Object { Write-Host ("  " + $_.Name + "  " + [math]::Round($_.Length / 1kb) + " KB") }
    Write-Host '提示：漏依赖的权威判据是 boxsend.dll 的导入表，可用 dumpbin /dependents 核对。'
}

# ---------- 2. WPF 界面 ----------
Step 'dotnet publish BoxSend.Windows'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
& dotnet publish $proj -c Release -r win-x64 --self-contained false -o $out -p:Version=$ver
if ($LASTEXITCODE) { throw "dotnet publish 失败" }

# ---------- 3. 体积概览 ----------
Step '成品体积'
$total = (Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("publish\ 合计 {0} MB（不含 .NET 桌面运行时本体）" -f [math]::Round($total / 1mb, 1))
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
