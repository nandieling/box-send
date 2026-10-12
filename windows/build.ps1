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
function Get-VsInstallPath {
    if ($script:vsPath) { return $script:vsPath }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $vswhere = if ($pf86) { Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe' } else { $null }
    if (-not $vswhere -or -not (Test-Path $vswhere)) { return $null }
    $script:vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                     -property installationPath | Select-Object -First 1
    return $script:vsPath
}

function Import-VsDevEnvironment {
    if ($env:INCLUDE -and $env:LIB) { return $false }      # 已经在开发者环境里，没东西可导
    $vs = Get-VsInstallPath
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
    $lines = @(& swift build -c $cfg --product boxsend-core 2>&1 | ForEach-Object { [string]$_ })
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

# C ABI 导出符号清单，与 Sources/BoxSendBridge/Exports.swift 里的 @_cdecl 对齐
$script:AbiExports = @('boxsend_create', 'boxsend_invoke', 'boxsend_free', 'boxsend_set_ocr',
                       'boxsend_version', 'boxsend_destroy', 'boxsend_last_error')

# PE 解析与加载：直接编界面工程里那份源码，脚本和界面看到的永远是同一张导入表
function Ensure-PeReader {
    if (-not $script:PeReady) {
        Add-Type -Path (Join-Path $proj 'Interop\PeReader.cs')
        $script:PeReady = $true
    }
}

# 读 PE 导出表 + 真加载一次的小助手。判空一律 ToInt64() 比 0，别把 IntPtr 丢给 PowerShell
# 转 bool——「等于 0」和「非 null」两种语义能把「7 个符号全缺」读成「7 个符号全有」，
# 带着空导出表的安装包就是这么混过冒烟测试的。

# 把导出符号情况打进日志并返回缺的名字（空数组 = 齐全）。-FileOnly 只查导出表不加载，
# 用在核心库刚编完那一步：加载了就得卸载，而 Swift 的 DLL 卸载不是件可靠的事，犯不上。
function Test-BoxSendExports([string]$dllPath, [switch]$FileOnly) {
    Ensure-PeReader
    $names = @([BoxSend.Windows.Interop.PeReader]::Exports($dllPath))
    $mine = @($names | Where-Object { $_ -like 'boxsend*' })
    $shown = if ($mine) { $mine -join ', ' } else { '一个都没有' }
    Write-Host ('  ' + (Split-Path -Leaf $dllPath) + '：导出表 ' + $names.Count + ' 项，boxsend* —— ' + $shown)
    if ($FileOnly) { return @($script:AbiExports | Where-Object { $names -notcontains $_ }) }
    $h = [BoxSend.Windows.Interop.NativeProbe]::Load($dllPath)
    if ($h.ToInt64() -eq 0) {
        $why = New-Object ComponentModel.Win32Exception ([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        throw "加载 $dllPath 失败（$why）"
    }
    return @($script:AbiExports | Where-Object {
        [BoxSend.Windows.Interop.NativeProbe]::Addr($h, $_) -eq 0 })
}

# 工具链里放 DLL 的目录：Swift 6 的 Windows 发行包是分家的，swift.exe 在 Toolchains\...\usr\bin，
# swiftCore.dll 这些运行时在 Runtimes\...\usr\bin，只扫前者会拷不全
function Get-ToolchainBins {
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
    return @($bins | Select-Object -Unique)
}

# VC 运行库（vcruntime140 / msvcp140）该从哪儿拷：VS 的 redist 目录是微软认可随包部署的那一份。
# 找不到（没装 VS）就返回空串，由调用方退回 System32。返回串而不是 $null，是为了能缓存
function Get-VcRedistDir {
    if ($null -ne $script:redistDir) { return $script:redistDir }
    $script:redistDir = ''
    $vs = Get-VsInstallPath
    if ($vs) {
        $d = Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending |
             ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -like 'Microsoft.VC*.vcruntime' } } |
             Select-Object -First 1 -ExpandProperty FullName
        if ($d) { $script:redistDir = $d }
    }
    return $script:redistDir
}

# 自包含的 .NET 只带它自己那份 _cor3 运行库，Swift 运行时是 MSVC 编的，要的是 VC 那套
$script:RedistPattern = '^(msvcp140|vcruntime140|concrt140|vccorlib)'

# 按导入表把依赖收全。Swift 运行时的 DLL 名跟着版本变（6.4 的 swift_Concurrency /
# swift_StringProcessing / swiftDispatch 就不在旧的那串通配里），照表追才不会漏；漏拷在 CI
# 上还不一定看得见——工具链目录就在 PATH 里，加载器能兜住，到用户机器上就是「找不到模块」
function Copy-CoreArtifacts([string]$built) {
    Ensure-PeReader
    New-Item -ItemType Directory -Force -Path $native | Out-Null
    Get-ChildItem $native -Filter *.dll | Remove-Item
    $script:copied = @()

    Copy-Item -LiteralPath (Join-Path $built 'boxsend-core.dll') (Join-Path $native 'boxsend-core.dll')
    $script:copied += 'boxsend-core.dll'

    # 只拷「真被导入」的那几个：上一次顺手把 VS redist 整个目录扫进来，多带了一份 debug 版
    # CRT（msvcp140d.dll 之流），白搭 4 MB
    $sources = @(Get-ToolchainBins)
    $redist = Get-VcRedistDir
    if ($redist) { $sources += $redist }
    $sys32 = Join-Path $env:SystemRoot 'System32'
    $seen = @{}
    $gaps = New-Object System.Collections.Generic.List[string]
    $q = New-Object System.Collections.Generic.Queue[string]
    $q.Enqueue((Join-Path $native 'boxsend-core.dll'))
    while ($q.Count) {
        $from = $q.Dequeue()
        $srcName = [IO.Path]::GetFileName($from)
        $key = $srcName.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        foreach ($imp in [BoxSend.Windows.Interop.PeReader]::Imports($from)) {
            if ([BoxSend.Windows.Interop.PeReader]::IsDownlevelApi($imp)) { continue }
            $to = Join-Path $native $imp
            if (-not (Test-Path -LiteralPath $to)) {
                $hit = @($sources | ForEach-Object { Join-Path $_ $imp }) |
                       Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($hit) { Copy-Item -LiteralPath $hit $to; $script:copied += $imp }
            }
            if (Test-Path -LiteralPath $to) { $q.Enqueue($to); continue }
            # VC 运行库算不算「系统自带」取决于那台机器装没装 redistributable，必须随包走；
            # 没装 VS 拷不到 redist 目录时，至少把本机 System32 那份带上
            if ($imp -match $script:RedistPattern) {
                $sys = Join-Path $sys32 $imp
                if (Test-Path -LiteralPath $sys) {
                    Copy-Item -LiteralPath $sys $to; $script:copied += $imp; $q.Enqueue($to)
                } else {
                    $gaps.Add("$imp（$srcName 导入；VS 的 redist 目录和 System32 里都没有）")
                }
            } elseif (-not (Test-Path -LiteralPath (Join-Path $sys32 $imp))) {
                $gaps.Add("$imp（$srcName 导入；工具链和 System32 里都没有）")
            }
        }
    }
    if ($gaps) { throw ('核心库的依赖凑不齐：' + ($gaps -join '；')) }

    $all = @(Get-ChildItem $native -Filter *.dll)
    Write-Host ('依赖闭包 ' + $all.Count + ' 个 DLL（本轮拷入 ' + $script:copied.Count + ' 个，按导入表追出来的）：')
    $all | Sort-Object Name | ForEach-Object { Write-Host ('  ' + $_.Name + '  ' + [math]::Round($_.Length / 1kb) + ' KB') }
}

# 成品自己说得清自己：每个 DLL 的导入项要么在成品里，要么是 Windows 自带。这一步不看 PATH，
# 装到干净机器上就是这一个目录，PATH 帮不上忙
function Test-BoxSendClosure([string]$dir) {
    Ensure-PeReader
    $sys32 = Join-Path $env:SystemRoot 'System32'
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem $native -File | ForEach-Object { Join-Path $dir $_.Name }) ) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $name = [IO.Path]::GetFileName($f)
        foreach ($m in [BoxSend.Windows.Interop.PeReader]::MissingDependencies($f, @($dir, $sys32))) {
            $bad.Add("$name 缺 $m")
        }
    }
    return @($bad)
}

# 版本号只有一个来源：核心库里的 BoxSendVersion
$verFile = Join-Path $root 'Sources\BoxSendKit\Util\Version.swift'
$verMatch = Select-String -Path $verFile -Pattern 'static let version = "([^"]+)"' | Select-Object -First 1
if (-not $verMatch) { throw '没能从 Version.swift 里读出版本号' }
$ver = $verMatch.Matches[0].Groups[1].Value
Write-Host ("BoxSend " + $ver) -ForegroundColor Green

# ---------- 1. 核心库 ----------
if (-not $SkipCore) {
    Step "swift build -c $Cfg --product boxsend-core"
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
    if (-not (Test-Path (Join-Path $built 'boxsend-core.dll'))) {
        throw "没找到 $built\boxsend-core.dll"
    }

    Step '把核心库和 Swift 运行时 DLL 收进 native\'
    Copy-CoreArtifacts $built
    # 先扫一眼导出表（只读文件不加载）。C ABI 符号没导出的话，装到用户机器上的表现是
    # 「核心库启动失败：Unable to find an entry point named 'boxsend_create'」，
    # 真加载的硬闸门在 2.5 步，这里只负责把问题暴露在刚编完的地方
    if (Test-BoxSendExports (Join-Path $native 'boxsend-core.dll') -FileOnly) {
        Write-Warning '核心库导出表不全，等 2.5 步真加载时再判一次'
    }

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

# ---------- 2.2 核心库到位 ----------
# csproj 用 Link 把 native\ 拍平到输出根目录。核心库的依赖（swiftCore.dll 那一堆）是运行期
# 动态加载的，Windows 只在「exe 所在目录 + PATH」里找，留在子目录里的表现是装上了却起不来
Step '核对 native\ 已拍平'
$leftBehind = @(Get-ChildItem (Join-Path $out 'native') -Recurse -File -ErrorAction SilentlyContinue)
if ($leftBehind) {
    throw ('这些文件还在 publish\native\ 里：' + (($leftBehind | ForEach-Object Name) -join ', ') `
           + '——csproj 里 native\ 那行的 Link 拍平规则被改了，核心库会加载不到')
}
$missingNative = @(Get-ChildItem $native -File | Where-Object { -not (Test-Path (Join-Path $out $_.Name)) } | ForEach-Object Name)
if ($missingNative) { throw ('这些 native 文件没进 publish\：' + ($missingNative -join ', ')) }
# 成品自己得说得清自己：每个 DLL 的导入项要么在成品里，要么是 Windows 自带。这一步跟 PATH
# 无关，装到用户机器上就是这一个目录，PATH 帮不上忙
$brokenChain = Test-BoxSendClosure $out
if ($brokenChain) { throw ('成品里的 DLL 缺依赖：' + ($brokenChain -join '；')) }

# ---------- 2.5 加载冒烟 ----------
# 装进安装包的就是这一份：真加载 + 逐个查符号，别等用户机器上弹「核心库启动失败」才知道
Step '加载 publish\boxsend-core.dll 冒烟测试'
$missing = Test-BoxSendExports (Join-Path $out 'boxsend-core.dll')
if ($missing) { throw ('导出符号缺失：' + ($missing -join ', ')) }
Write-Host '加载成功，7 个导出符号齐全' -ForegroundColor Green

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
